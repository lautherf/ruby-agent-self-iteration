# frozen_string_literal: true

require 'fileutils'
require 'thread'
require 'time'
require_relative 'doc'

module RubyAgent
  # Memory —— 对话记忆，且"记忆即代码"（Sprint 7）。
  #
  # 愿景：记忆不是数据库行，而是一段"跑起来就能读出记忆"的真代码——
  #   每条记忆 = 一个 def，方法体就是记忆内容（谁都能一眼看懂、也能真执行）；
  #   `# @doc` 注释只放元数据（who/since/tags），note 由代码求值出来，磁盘零重复。
  #
  # 双通道（同一份 memory.rb）：
  #   turn_XXX   原始对话流水：who/user/ra + since(+tags)，方法体 = 说的内容。
  #             AgentLoop 每轮结束自动沉淀一条，ra 也能用 remember 工具显式记。
  #   lesson_XXX 折叠后的压缩经验：IterationLoop 每轮把窗口外的老 turn 折叠进来。
  #
  # 安全设计与 Knowledge 同构：白名单校验 → 试编译 → tmp + rename 原子落盘，
  # 任何一步失败即丢弃，毒记忆不可能落盘。
  class Memory
    # 挂载到 DocHub 时的插件名（经 for_llm 注入 system prompt，与 knowledge 一致）
    NAME = 'memory'

    # 新建记忆文件时的头注释（纯注释，不进入契约解析）
    DEFAULT_HEADER = <<~RUBY
      # frozen_string_literal: true

      # 记忆即代码：记忆是可执行的 Ruby —— 每条记忆 = 一个返回内容的 def。
      # 方法体就是记忆本身；上方 # @doc 只放元数据（who/since/tags）。
      # turn_XXX = 原始对话；lesson_XXX = 折叠经验。可编译、可回滚、可 git diff、可遗忘。
    RUBY

    # 缺省折叠摘要：不调用 LLM，确定性给出合并说明；传 summarize: 可换真实模型摘要。
    DEFAULT_SUMMARIZE = lambda { |batch|
      who = batch.map { |t| t[:who] }.compact.uniq.join('/')
      "与 #{who} 进行了 #{batch.size} 条对话，已折叠为经验，细节不再逐条保留"
    }

    attr_reader :path

    def initialize(path)
      @path = path
      @registry = {}
      @mutex = Mutex.new
      ensure_file!
      load!
    end

    # 空记忆也是合法代码：缺文件时先落 DEFAULT_HEADER（与 IterationLoop 挂载行为一致）
    def ensure_file!
      return if File.exist?(@path)

      FileUtils.mkdir_p(File.dirname(@path)) unless File.directory?(File.dirname(@path))
      File.write(@path, DEFAULT_HEADER)
    end

    # 重读磁盘：解析 # @doc 元数据 + 求值方法体，note 由代码提供（失败保留旧 view）。
    # 以代码为准：Doc.parse 只认有 @doc 的方法，而方法体才是记忆本身——
    # 凡是有方法体（哪怕没注释契约）都登记进来，note 来自代码求值。
    def load!
      parsed = File.exist?(@path) ? Doc.parse(@path) : {}
      self.class.eval_bodies(@path).each { |id, value| (parsed[id] ||= {})['note'] = value }
      @registry = parsed
      self
    rescue StandardError => e
      warn "[Memory] 加载失败，保留旧 view: #{e.message}"
      self
    end

    # 求值记忆文件：返回 { 方法名 => def 体返回的内容 }。
    # 记忆=代码：把 memory.rb module_eval 进匿名模块，每条 def 一调用，记忆就读回来了。
    def self.eval_bodies(path)
      return {} unless File.exist?(path)

      mod = Module.new
      mod.module_eval(File.read(path), path, 1)
      probe = Object.new.extend(mod)
      mod.instance_methods(false).each_with_object({}) do |name, h|
        h[name.to_s] = probe.public_send(name)
      end
    rescue StandardError
      {}
    end

    # 全部原始对话（按文件顺序）
    def turns
      ordered.select { |(id, _) | id.start_with?('turn_') }
             .map { |id, a| slice_turn(id, a) }
    end

    # 全部折叠经验
    def lessons
      ordered.select { |(id, _) | id.start_with?('lesson_') }
             .map { |id, a| slice_lesson(id, a) }
    end

    # 记一条对话。返回落盘后的 id；失败返回 false。
    def add_turn(who: 'ra', note:, tags: nil, since: Time.now.utc.iso8601)
      note = note.to_s.strip
      attrs = { 'who' => who.to_s, 'note' => note, 'since' => since.to_s }
      tags = tags.to_s.strip
      attrs['tags'] = tags unless tags.empty?
      return false if note.empty?

      add_stub('turn', attrs)
    end

    # 折一条经验（预留通道，独立于 Knowledge；供 consolidate 内部使用）
    def add_lesson(note, tags: nil)
      note = note.to_s.strip
      attrs = { 'note' => note }
      tags = tags.to_s.strip
      attrs['tags'] = tags unless tags.empty?
      return false if note.empty?

      add_stub('lesson', attrs)
    end

    # 按内容召回对话：query 空格分词，命中任意词即召回（多词查询如"项目 颜色"好使）；
    # query 为空返回最近 limit 条（最新在前）。
    def recall(query: nil, limit: 5)
      list = turns.reverse
      q = query.to_s.strip
      return list.first(limit) if q.empty?

      terms = q.downcase.split(/\s+/).reject(&:empty?)
      list = list.select do |t|
        blob = [t[:who], t[:note], t[:tags]].compact.join(' ').downcase
        terms.any? { |term| blob.include?(term) }
      end
      list.first(limit)
    end

    # 折叠：把窗口外的老对话压缩成一条 lesson（遗忘=重构）。
    # 传入 summarizer（callable 接收旧 turns 数组，返回摘要文本）；
    # 落盘后旧 turn 存根被删除、保留最近 keep 条原始对话 + 所有 lesson。
    def consolidate!(keep: 5, &summarizer)
      summarizer ||= DEFAULT_SUMMARIZE

      reg = snapshot
      turn_ids = reg.keys.select { |k| k.start_with?('turn_') }
      fold_ids = turn_ids.size > keep ? turn_ids[0...-keep] : []
      return false if fold_ids.empty?

      batch = fold_ids.map { |id| slice_turn(id, reg[id]) }
      note = summarizer.call(batch).to_s.strip
      return false if note.empty?

      @mutex.synchronize do
        lesson_ids = reg.keys.select { |k| k.start_with?('lesson_') }
        summary_id = format('lesson_%03d', lesson_ids.map { |id| id[/\d+/].to_i }.max.to_i + 1)
        content = DEFAULT_HEADER.dup
        content = content.chomp + "\n" unless content.end_with?("\n")
        lesson_ids.each { |id| content << stub_block(id, reg[id]) }
        (turn_ids - fold_ids).each { |id| content << stub_block(id, reg[id]) }
        content << stub_block(summary_id, { 'note' => note })

        RubyVM::InstructionSequence.compile(content)
        write_atomic(content)
        load!
        summary_id
      end
    rescue SyntaxError, StandardError => e
      warn "[Memory] 折叠失败，已丢弃: #{e.message}"
      false
    end

    # 记忆即代码 → 也是一个可挂载插件，记忆随 for_llm 注入 system prompt。
    def plugin
      MemoryPlugin.new(NAME, @path)
    end

    # 记忆插件的加载器：Doc.parse 只给元数据，note 藏在方法体里 → 求值补全（以代码为准）。
    # 这样 Memory 本体、DocHub 热重载、IterationLoop 每轮 load! 看到的契约都一致。
    class MemoryPlugin < DocPlugin
      def load!
        parsed = Doc.parse(@path)
        Memory.eval_bodies(@path).each { |id, value| (parsed[id] ||= {})['note'] = value }
        @registry = parsed
        self
      rescue StandardError => e
        warn "[#{@name}] 加载失败，保留旧版: #{e.message}"
        self
      end
    end

    private

    def snapshot
      @mutex.synchronize { @registry.dup }
    end

    def ordered
      @mutex.synchronize { @registry.to_a }
    end

    def slice_turn(id, attrs)
      { id: id, who: attrs['who'], note: attrs['note'], since: attrs['since'], tags: attrs['tags'] }
    end

    def slice_lesson(id, attrs)
      { id: id, note: attrs['note'], tags: attrs['tags'] }
    end

    # 追加一条记忆：契约校验元数据 → 试编译 → tmp 原子 rename（与 Knowledge 同安全模型）
    def add_stub(prefix, attrs)
      id = nil
      @mutex.synchronize do
        id = next_id(prefix)
        meta = attrs.reject { |k, _| k == 'note' }
        Doc.validate!(meta)                     # 注释层只校验元数据；note 是方法体，由代码层兜底
        content = File.exist?(@path) ? File.read(@path) : DEFAULT_HEADER
        content = content.chomp + "\n" unless content.end_with?("\n")
        new_src = content + stub_block(id, attrs)
        RubyVM::InstructionSequence.compile(new_src)  # 代码层试编译
        write_atomic(new_src)
        @registry[id] = attrs
      end
      id
    rescue SyntaxError, StandardError => e
      warn "[Memory] 写入失败，已丢弃: #{e.message}"
      false
    end

    def next_id(prefix)
      count = @registry.keys.count { |k| k.start_with?("#{prefix}_") }
      format("#{prefix}_%03d", count + 1)
    end

    # 一条记忆的落盘代码：元数据进 # @doc 注释，内容变成方法体（inspect 保证任意文本安全）。
    def stub_block(id, attrs)
      payload = attrs['note'].to_s
      meta = attrs.reject { |k, _| k == 'note' }
      doc = meta.filter_map { |k, v| "# @doc #{k}: #{v}\n" }.join
      body = payload.empty? ? '' : "\n  #{payload.inspect}\n"
      "#{doc}def #{id}#{body}end\n"
    end

    def write_atomic(src)
      tmp = "#{@path}.tmp"
      File.write(tmp, src)
      File.rename(tmp, @path)
    end
  end
end