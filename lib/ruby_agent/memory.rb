# frozen_string_literal: true

require 'fileutils'
require 'thread'
require 'time'
require 'yaml'

module RubyAgent
  # Memory —— 记忆 = 结构化数据文件 + 简单读写；Ruby 代码只当"本体论"。
  #
  # —— 本体论宣言："足够好"的五条标准 ——
  # 1. 真（epistemic）：每条记忆必须能说清"多可信、怎么来的"
  #      → status：stated 刚听说 / confirmed ra 亲自验证过 / superseded 已被更新取代 / doubted 存疑。
  # 2. 分（kinds 匹配现实）：fact / preference / task / event / meta / lesson。
  #      → 分法是"跑出来的"：demo 里 task 一度被拒，说明本体论缺这类，靠现实补。
  # 3. 联（references）：记忆与记忆用 id 连线 —— supersedes（新取代旧）、lesson.from（经验源自哪几条 turn）。
  #      → 不做 RDF 图，够 recall 与注入用就该收手。
  # 4. 变（truth 随时间变）：偏好会变、常识会旧。改 = 写一条新记录并把旧记录标 superseded，
  #      → 不覆盖原件（原件是历史证据），真相由"链头"决定。
  # 5. 简（够用即止）：YAML + 字符串 note + id 引用。多一个字段必须多解决一个真实问题。
  #
  # 双通道（同一份 YAML）：turn_XXX 原始对话流水 / lesson_XXX 折叠经验。
  class Memory
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

    # —— 本体论：谁有资格当发言者（who）——（证词来源必须是这四者之一）
    WHO = %w[user ra system tool].freeze

    # —— 本体论：认知状态（status）——（每条记录都必须回答"可信度几何"）
    STATUS = {
      stated:     '刚记录/刚听说，未经核实',
      confirmed:  'ra 亲自验证过（如 apply+verify 通过）',
      superseded: '已被更新的记录取代，不再采信',
      doubted:    '与其它证据冲突，存疑待查'
    }.freeze

    # —— 本体论：实体（表）与受控字段 ——
    ENTITIES = {
      turn:   { table: 'turns',   kinds: %i[fact preference task event meta], required: %w[who note] },
      lesson: { table: 'lessons', kinds: %i[lesson],                           required: %w[note] }
    }.freeze

    # 合法字段：id 标识 / kind 种类 / who 发言者 / about 关于谁（可选主语）
    # note 内容 / status 认知状态 / since 记录时间 / tags 标签
    # supersedes 取代了哪条（联）/ from 由哪些 turn 折叠而来（联，仅 lesson）
    FIELDS = %w[id kind who about note status since tags supersedes from].freeze
    MAX_NOTE = 2000

    # 缺省折叠摘要：不调用 LLM，确定性给出合并说明；传 summarize: 可换真实模型摘要。
    DEFAULT_SUMMARIZE = lambda { |batch|
      who = batch.map { |t| t[:who] }.compact.uniq.join('/')
      "与 #{who} 进行了 #{batch.size} 条对话，已折叠为经验，细节不再逐条保留"
    }

    # 空记忆文件头（注释不进解析，只为可读性）
    DEFAULT_HEADER = <<~YAML
      # 记忆本体结构化数据：turn（原始对话）/ lesson（折叠经验）。
      # 字段由 Memory 本体论约束——kind/who/status 各有受控取值，supersedes 与 from 是记录间的关系。
      # 这是纯数据，由 Memory 引擎读写；本体论与原子落盘都在代码里。
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

    # 全部原始对话（按文件顺序，含 superseded 的原件——原件是历史证据）
    def turns
      ordered('turns').map { |t| slice(t, %i[id kind who about note status since tags supersedes]) }
    end

    # 全部折叠经验
    def lessons
      ordered('lessons').map { |l| slice(l, %i[id kind note status since tags from]) }
    end

    # 记一条对话。缺省 status=stated；kind 受 KINDS 约束；返回落盘 id；校验失败返回 false。
    def add_turn(who: 'ra', note:, tags: nil, since: Time.now.utc.iso8601, kind: 'fact',
                 about: nil, status: 'stated', supersedes: nil)
      add(ENTITY(:turn),
          who: who, note: note, tags: tags, since: since, kind: kind,
          about: about, status: status, supersedes: supersedes)
    end

    # 折一条经验（供 consolidate 内部使用；engine 亲手折的 → confirmed）
    def add_lesson(note, tags: nil, since: Time.now.utc.iso8601, from: nil)
      add(ENTITY(:lesson), note: note, tags: tags, since: since, kind: 'lesson', status: 'confirmed', from: from)
    end

    # 标记某条已废弃（变：真相被更新取代时不覆盖原件，只改状态）
    def mark_superseded!(id)
      @mutex.synchronize do
        rec = @data['turns'].find { |r| r['id'] == id } || @data['lessons'].find { |r| r['id'] == id }
        return false unless rec

        rec['status'] = 'superseded'
        write_atomic(@data)
      end
    rescue StandardError
      false
    end

    # 修订（变的标准入口）：旧记录标 superseded，同时写入新记录并指向旧记录。
    def revise!(target_id, note:, kind: 'fact', tags: nil, about: nil)
      return false unless mark_superseded!(target_id)

      add_turn(who: 'ra', note: note, tags: tags, kind: kind,
               about: about, status: 'confirmed', supersedes: target_id)
    end

    # 按内容召回：query 空格分词，命中任意词即召回；query 为空返回最近 limit 条（最新在前）。
    # 缺省不返已废弃记录（include_superseded: true 才看原件）。
    def recall(query: nil, limit: 5, include_superseded: false)
      list = turns.reverse
      list = list.reject { |t| t[:status] == 'superseded' } unless include_superseded

      q = query.to_s.strip
      return list.first(limit) if q.empty?

      terms = q.downcase.split(/\s+/).reject(&:empty?)
      list = list.select do |t|
        blob = [t[:who], t[:about], t[:note], t[:kind], t[:tags]].compact.join(' ').downcase
        terms.any? { |term| blob.include?(term) }
      end
      list.first(limit)
    end

    # 最近若干条记忆（供 AgentLoop 直接注入 system prompt；跳过已废弃，标出可信度）
    def recent(limit: 8)
      recall(limit: limit)
    end

    # 折叠：把窗口外的老对话压缩成一条 lesson（遗忘=重构）。
    # lesson 用 from 留下折叠来源（联：经验可追溯）；返回新 lesson 的 id，无可折叠时 false。
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
      lesson = validate!(ENTITY(:lesson),
                         'id' => lesson_id, 'kind' => 'lesson', 'note' => note,
                         'since' => Time.now.utc.iso8601, 'tags' => [],
                         'status' => 'confirmed', 'from' => fold_ids)

      @mutex.synchronize do
        @data['lessons'] << lesson
        @data['turns'] = @data['turns'].select { |r| fold_ids.include?(r['id']).! }
        write_atomic(@data) && lesson_id
      end
    rescue StandardError => e
      warn "[Memory] 折叠失败，已丢弃: #{e.message}"
      false
    end

    # AgentLoop 直接注入用：turns + lessons，跳过已废弃，标注可信度与取代关系。
    def for_llm
      lines = (turns + lessons).reject { |r| r[:status] == 'superseded' }
      return '' if lines.empty?

      lines.map { |r| format_llm(r) }.join("\n")
    end

    private

    def ENTITY(key)
      ENTITIES.fetch(key)
    end

    def format_llm(r)
      tag = r[:status] && r[:status] != 'stated' ? "[#{r[:status]}]" : ''
      rel = r[:supersedes] ? " (取代 #{r[:supersedes]})" : ''
      "- #{r[:id]}#{tag}[#{r[:kind]}] #{r[:note]}#{rel}"
    end

    # —— 本体论契约校验：受控取值 + 必填 + note 非空 + 关系引用必须真实存在 ——
    def validate!(entity, rec)
      unknown = rec.keys - FIELDS
      raise ArgumentError, "非法字段: #{unknown.join(',')}" unless unknown.empty?

      raise ArgumentError, "非法 kind: #{rec['kind']}" unless entity[:kinds].map(&:to_s).include?(rec['kind'].to_s)
      raise ArgumentError, "非法 who: #{rec['who']}" if rec.key?('who') && !rec['who'].to_s.empty? && !WHO.include?(rec['who'].to_s)
      raise ArgumentError, "非法 status: #{rec['status']}" unless STATUS.key?(rec['status'].to_s.to_sym) || STATUS.key?(rec['status'])

      entity[:required].each do |k|
        raise ArgumentError, "缺少必填字段 #{k}" if rec[k].to_s.strip.empty?
      end

      note = rec['note'].to_s.strip
      raise ArgumentError, '记忆内容不能为空' if note.empty?
      raise ArgumentError, "note 超过 #{MAX_NOTE} 字" if note.length > MAX_NOTE

      if rec['supersedes'] && !rec['supersedes'].to_s.empty? && !known_id?(rec['supersedes'])
        raise ArgumentError, "supersedes 指向不存在的记录: #{rec['supersedes']}"
      end

      from = Array(rec['from']).map(&:to_s).reject(&:empty?)
      unknown_from = from - known_turn_ids
      raise ArgumentError, "from 包含不存在的 turn: #{unknown_from.join(',')}" unless unknown_from.empty?

      rec.merge('kind' => rec['kind'].to_s,
                'note' => note,
                'status' => rec['status'].to_s,
                'tags' => Array(rec['tags']).flat_map { |s| s.to_s.split(',') }
                            .map(&:strip).reject(&:empty?).uniq,
                'about' => rec['about'].to_s,
                'from' => from,
                'supersedes' => rec['supersedes'].to_s,
                'since' => rec['since'].to_s)
    end

    def add(entity, who: nil, note:, tags: nil, since: Time.now.utc.iso8601, kind: nil,
            about: nil, status: 'stated', supersedes: nil, from: nil)
      record = { 'kind' => kind, 'note' => note.to_s, 'tags' => tags,
                 'since' => since.to_s, 'about' => about, 'status' => status,
                 'supersedes' => supersedes, 'from' => from }
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

    def known_id?(id)
      id = id.to_s
      @data['turns'].any? { |r| r['id'] == id } || @data['lessons'].any? { |r| r['id'] == id }
    end

    def known_turn_ids
      @mutex.synchronize { @data['turns'].map { |r| r['id'] } }
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
      rec = rec.slice(*FIELDS)
      rec['status'] = 'stated' if rec['status'].nil? || rec['status'].to_s.empty?
      rec.to_h { |k, v| [k, v.is_a?(Array) ? v.map(&:to_s) : v.to_s] }
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