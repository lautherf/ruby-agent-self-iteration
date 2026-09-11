# frozen_string_literal: true

require 'fileutils'
require 'thread'
require 'time'
require 'yaml'

module RubyAgent
  # Memory —— 记忆 = 结构化数据文件 + 简单读写；Ruby 代码在这里只当"本体论"。
  #
  # 本体论（代码部分）：SCHEMA 声明"记忆是什么"——
  #   ENTITIES：turn（原始对话流水）/ lesson（折叠经验）的字段与必填项；
  #   KINDS：记忆的种类（事实/偏好/事件/元记忆/经验）；
  #   FIELDS：允许出现的字段白名单。
  # 代码用本体论做契约校验 → 按字段重建 → tmp+rename 原子落盘（写后读回自检）。
  #
  # 内容本体：存在 memory.yaml —— 纯结构化数据，简单读写（YAML.load / YAML.dump），
  # 不搞"方法体装内容"的把戏；可 diff、可手改、空文件也是合法数据。
  #
  # 双通道（同一份 YAML）：
  #   turn_XXX   原始对话：who × since × tags，note = 原话。AgentLoop 自动沉淀 / remember 显式记。
  #   lesson_XXX 折叠经验：IterationLoop 每轮把窗口外的老 turn 折叠成一条（遗忘=重构）。
  class Memory
    # 挂载名（保留语义：记忆仍是 ra 的一个"器官"，只是不再伪装成 DocPlugin）
    NAME = 'memory'

    # —— 本体论：记忆的种类（kind）——
    KINDS = {
      fact:       '事实：关于用户/项目/世界的不变陈述',
      preference: '偏好：用户喜欢什么、习惯怎么做',
      task:       '任务：用户布置的请求/工作',
      event:      '事件：发生过的一件具体的事',
      meta:       '元记忆：关于记忆/系统本身的说明',
      lesson:     '经验：多段对话折叠出的教训或结论'
    }.freeze

    # —— 本体论：实体（表）与受控字段 ——
    ENTITIES = {
      turn:   { table: 'turns',   kinds: %i[fact preference task event meta], required: %w[who note] },
      lesson: { table: 'lessons', kinds: %i[lesson],                          required: %w[note] }
    }.freeze

    FIELDS = %w[id kind who note since tags].freeze
    MAX_NOTE = 2000

    # 缺省折叠摘要：不调用 LLM，确定性给出合并说明；传 summarize: 可换真实模型摘要。
    DEFAULT_SUMMARIZE = lambda { |batch|
      who = batch.map { |t| t[:who] }.compact.uniq.join('/')
      "与 #{who} 进行了 #{batch.size} 条对话，已折叠为经验，细节不再逐条保留"
    }

    # 空记忆文件头（注释不进解析，只为可读性）
    DEFAULT_HEADER = <<~YAML
      # 记忆本体：turn（原始对话）/ lesson（折叠经验），字段由 Memory::SCHEMA 本体论约束。
      # 这是纯结构化数据，由 Memory 引擎读写；代码才是本体论与原子落盘的所在地。
    YAML

    attr_reader :path

    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @data = {}
      ensure_file!
      load!
    end

    # 空记忆也是合法数据：缺文件时先落空文档（turns: [] / lessons: []）
    def ensure_file!
      return if File.exist?(@path)

      FileUtils.mkdir_p(File.dirname(@path)) unless File.directory?(File.dirname(@path))
      write_atomic(empty_data)
    end

    # 重读磁盘（YAML.parse → 校验 → 规范化；失败保留旧 view）
    def load!
      parsed = File.exist?(@path) ? parse_file(@path) : empty_data
      @data = normalize(parsed)
      self
    rescue StandardError => e
      warn "[Memory] 加载失败，保留旧 view: #{e.message}"
      self
    end

    # 全部原始对话（按文件顺序）
    def turns
      ordered('turns').map { |t| slice(t, %i[id kind who note since tags]) }
    end

    # 全部折叠经验
    def lessons
      ordered('lessons').map { |l| slice(l, %i[id kind note since tags]) }
    end

    # 记一条对话。kind 受 KINDS 约束；返回落盘后的 id；校验失败返回 false。
    def add_turn(who: 'ra', note:, tags: nil, since: Time.now.utc.iso8601, kind: 'fact')
      add(ENTITY(:turn), who: who, note: note, tags: tags, since: since, kind: kind)
    end

    # 折一条经验（供 consolidate 内部使用）
    def add_lesson(note, tags: nil, since: Time.now.utc.iso8601)
      add(ENTITY(:lesson), note: note, tags: tags, since: since, kind: 'lesson')
    end

    # 按内容召回：query 空格分词，命中任意词即召回；query 为空返回最近 limit 条（最新在前）。
    def recall(query: nil, limit: 5)
      list = turns.reverse
      q = query.to_s.strip
      return list.first(limit) if q.empty?

      terms = q.downcase.split(/\s+/).reject(&:empty?)
      list = list.select do |t|
        blob = [t[:who], t[:note], t[:kind], t[:tags]].compact.join(' ').downcase
        terms.any? { |term| blob.include?(term) }
      end
      list.first(limit)
    end

    # 最近若干条记忆（供 AgentLoop 直接注入 system prompt）
    def recent(limit: 8)
      recall(limit: limit)
    end

    # 折叠：把窗口外的老对话压缩成一条 lesson（遗忘=重构）。
    # 落盘后文件只留最近 keep 条原始对话 + 全部 lesson；返回新 lesson 的 id，无可折叠时 false。
    def consolidate!(keep: 5, &summarizer)
      summarizer ||= DEFAULT_SUMMARIZE

      snapshot = @mutex.synchronize { marshal }
      turn_ids = snapshot['turns'].map { |r| r['id'] }
      fold_ids = turn_ids.size > keep ? turn_ids[0...-keep] : []
      return false if fold_ids.empty?

      batch = fold_ids.map { |id| record_hash(snapshot['turns'].find { |r| r['id'] == id }) }
      note = summarizer.call(batch).to_s.strip
      return false if note.empty?

      lesson_id = next_id(snapshot['lessons'], 'lesson')
      lesson    = validate!(ENTITY(:lesson), 'id' => lesson_id, 'kind' => 'lesson',
                             'note' => note, 'since' => Time.now.utc.iso8601, 'tags' => [])

      @mutex.synchronize do
        @data['lessons'] << lesson
        @data['turns'] = @data['turns'].select { |r| fold_ids.include?(r['id']).! }
        write_atomic(@data) && lesson_id
      end
    rescue StandardError => e
      warn "[Memory] 折叠失败，已丢弃: #{e.message}"
      false
    end

    # AgentLoop 直接注入用：与 @doc 文档插件同风格的简单文本
    def for_llm
      lines = turns + lessons
      return '' if lines.empty?

      lines.map { |r| "- #{r[:id]}[#{r[:kind]}] #{r[:note]}" }.join("\n")
    end

    private

    def ENTITY(key)
      ENTITIES.fetch(key)
    end

    # —— 本体论契约校验：字段白名单 + kind 取值域 + 必填 + note 非空 ——
    def validate!(entity, rec)
      unknown = rec.keys - FIELDS
      raise ArgumentError, "非法字段: #{unknown.join(',')}" unless unknown.empty?

      raise ArgumentError, "非法 kind: #{rec['kind']}" unless entity[:kinds].map(&:to_s).include?(rec['kind'].to_s)

      entity[:required].each do |k|
        raise ArgumentError, "缺少必填字段 #{k}" if rec[k].to_s.strip.empty?
      end

      note = rec['note'].to_s.strip
      raise ArgumentError, '记忆内容不能为空' if note.empty?
      raise ArgumentError, "note 超过 #{MAX_NOTE} 字" if note.length > MAX_NOTE

      rec.merge('kind' => rec['kind'].to_s,
                'note' => note,
                'tags' => Array(rec['tags']).flat_map { |s| s.to_s.split(',') }
                            .map(&:strip).reject(&:empty?).uniq,
                'since' => rec['since'].to_s)
    end

    def add(entity, who: nil, note:, tags: nil, since: Time.now.utc.iso8601, kind: nil)
      note = note.to_s
      record = { 'kind' => kind, 'note' => note, 'tags' => tags, 'since' => since.to_s }
      record['who'] = who.to_s if who
      record = validate!(entity, record)

      @mutex.synchronize do
        id = next_id(@data[entity[:table]], ENTITY_PREFIX(entity))
        rec = record.merge('id' => id)
        @data[entity[:table]] << rec
        write_atomic(@data) && id
      end
    rescue StandardError => e
      warn "[Memory] 写入失败，已丢弃: #{e.message}"
      false
    end

    def ENTITY_PREFIX(entity)
      entity[:table].sub(/s\z/, '')
    end

    def empty_data
      { 'turns' => [], 'lessons' => [] }
    end

    # 落盘：dump → 暂存 → 读回自检（本轮解析必须成功才算数）→ 原子 rename。
    # 任何一步失败即丢弃：磁盘上要么是旧版完整文件，要么是新版完整文件。
    def write_atomic(data)
      tmp = "#{@path}.tmp"
      File.write(tmp, render(data))
      parse_file(tmp)
      File.rename(tmp, @path)
      true
    rescue StandardError
      FileUtils.rm_f(tmp)
      false
    end

    def render(data)
      DEFAULT_HEADER + YAML.dump(data)
    end

    def parse_file(file)
      YAML.safe_load(File.read(file), permitted_classes: [Symbol], aliases: false)
    rescue StandardError => e
      raise ParseError, e.message
    end

    class ParseError < StandardError; end

    # 规范化：只认 turns/lessons 两张表，行记录字段受限 FIELDS，非法行丢弃。
    def normalize(parsed)
      parsed = {} unless parsed.is_a?(Hash)
      empty_data.merge(
        'turns'   => Array(parsed['turns']).select { |r| r.is_a?(Hash) }
                       .map { |r| normalize_record(r) }.compact,
        'lessons' => Array(parsed['lessons']).select { |r| r.is_a?(Hash) }
                        .map { |r| normalize_record(r) }.compact
      )
    end

    def normalize_record(rec)
      rec.slice(*FIELDS)
         .to_h { |k, v| [k, v.is_a?(Array) ? v.map(&:to_s) : v.to_s] }
    rescue StandardError
      nil
    end

    def ordered(table)
      @mutex.synchronize { @data[table] }
    end

    def slice(rec, keys)
      keys.each_with_object({}) { |k, h| h[k] = rec[k.to_s] }
    end

    def record_hash(rec)
      rec.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end

    # id 递增：取表内现有最大编号 +1，避免折叠删行后编号回退/重复
    def next_id(rows, prefix)
      max = rows.map { |r| r['id'].to_s[/\d+/].to_i }.max.to_i
      format('%s_%03d', prefix, max + 1)
    end

    def marshal
      @data.transform_values { |rows| rows.map(&:dup) }
    end
  end
end