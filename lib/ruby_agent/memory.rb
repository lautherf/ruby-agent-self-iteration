# frozen_string_literal: true

require 'fileutils'
require 'thread'
require 'time'
require_relative 'doc'

module RubyAgent
  # Memory —— 对话记忆，且"记忆即代码"（Sprint 7）。
  #
  # 愿景：记忆不是数据库行，而是 Ruby 文件里的存根方法 + `# @doc` 注释契约，
  # 与 lessons 同构、可编译、可回滚、可 git diff、可遗忘（删存根/折叠成 lesson）。
  #
  # 双通道（同一份 memory.rb）：
  #   turn_XXX   原始对话流水：who/user/ra + note + since(+tags)，
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

      # 记忆即代码：ra 的对话记忆与折叠经验全部以"存根方法 + @doc 契约"存在这里。
      # turn_XXX = 原始对话流水（who/note/since）；lesson_XXX = 压缩后的经验。
      # 记忆是可编译代码：可回滚、可 git diff、可遗忘（删存根 / 折叠成 lesson）。
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

    # 重读磁盘：让新增记忆进入本对象的内存 view（失败保留旧 view）
    def load!
      @registry = File.exist?(@path) ? Doc.parse(@path) : {}
      self
    rescue StandardError => e
      warn "[Memory] 加载失败，保留旧 view: #{e.message}"
      self
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

    # 按内容召回对话：query 模糊匹配 who/note/tags，缺省返回最近 limit 条（最新在前）。
    def recall(query: nil, limit: 5)
      q = query.to_s.strip.downcase
      list = turns.reverse
      unless q.empty?
        list = list.select { |t| [t[:who], t[:note], t[:tags]].compact.join(' ').downcase.include?(q) }
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
        @registry = Doc.parse(@path)
        summary_id
      end
    rescue SyntaxError, StandardError => e
      warn "[Memory] 折叠失败，已丢弃: #{e.message}"
      false
    end

    # 记忆即代码 → 也是一个可挂载插件，记忆随 for_llm 注入 system prompt。
    def plugin
      DocPlugin.new(NAME, @path)
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

    # 追加一个存根方法：契约校验 → 试编译 → tmp 原子 rename（与 Knowledge 同安全模型）
    def add_stub(prefix, attrs)
      @mutex.synchronize do
        id = next_id(prefix)
        Doc.validate!(attrs)                     # 注释层设闸：白名单 key / 禁换行 / 长度上限
        content = File.exist?(@path) ? File.read(@path) : DEFAULT_HEADER
        content = content.chomp + "\n" unless content.end_with?("\n")
        new_src = content + stub_block(id, attrs)
        RubyVM::InstructionSequence.compile(new_src)  # 代码层试编译
        write_atomic(new_src)
        @registry[id] = attrs
        id
      end
    rescue SyntaxError, StandardError => e
      warn "[Memory] 写入失败，已丢弃: #{e.message}"
      false
    end

    def next_id(prefix)
      count = @registry.keys.count { |k| k.start_with?("#{prefix}_") }
      format("#{prefix}_%03d", count + 1)
    end

    def stub_block(id, attrs)
      block = attrs.filter_map { |k, v| "# @doc #{k}: #{v}\n" }.join
      "#{block}def #{id}\nend\n"
    end

    def write_atomic(src)
      tmp = "#{@path}.tmp"
      File.write(tmp, src)
      File.rename(tmp, @path)
    end
  end
end