# frozen_string_literal: true

require 'thread'
require_relative 'doc'

module RubyAgent
  # Knowledge —— 经验仓库（Sprint 5 知识沉淀）。
  #
  # 目标：让 Agent 把「这次任务学到的东西」持久化为可被下次迭代读取的契约知识。
  #
  # 持久化格式复用具名注释契约：每个 lesson 是 lessons.rb 里
  #   `# @doc note: <经验>` 上方悬空的 `def lesson_XXX\nend` 存根，
  # 因此天然被 Doc.parse / DocPlugin / for_llm 复用，无需第二套格式。
  #
  # 原子性：读-改-写全程持锁，落盘走 tmp + rename，任一步失败即丢弃（失败关闭）。
  class Knowledge
    # 挂载到 DocHub 时的插件名（IterationLoop 用它把知识喂回循环）
    NAME = 'knowledge'

    # 新建知识文件时的头注释（纯注释，不进入契约解析）
    DEFAULT_HEADER = <<~RUBY
      # frozen_string_literal: true

      # 经验沉淀区：Agent 每次迭代后把学到的经验写在这里。
      # 每次迭代开始前，这里的内容会随 for_llm 注入 system prompt，
      # 让下一次迭代站在已沉淀的知识上出发。
    RUBY

    attr_reader :path

    def initialize(path)
      @path = path
      @registry = {}
      @mutex = Mutex.new
      load!
    end

    # 重读磁盘：让新增的知识进入本对象的内存 view（失败保留旧 view）
    def load!
      @registry = File.exist?(@path) ? Doc.parse(@path) : {}
      self
    rescue StandardError => e
      warn "[Knowledge] 加载失败，保留旧 view: #{e.message}"
      self
    end

    # 全部经验：[{ id:, note:, tags: }]
    def lessons
      @registry.map do |id, attrs|
        { id: id, note: attrs['note'], tags: attrs['tags'] }
      end
    end

    # 沉淀一条经验。返回落盘后的 id（字符串）；重复内容返回既有 id；失败返回 false。
    # 线程安全：读-改-写在同一把锁里完成，绝不产生 lost update。
    def add(lesson, tags: nil)
      note = lesson.to_s.strip
      return false if note.empty?

      @mutex.synchronize do
        existing = @registry.find { |_, attrs| attrs['note'] == note }
        return existing.first if existing

        id = next_id
        attrs = { 'note' => note }
        tags = tags.to_s.strip
        attrs['tags'] = tags unless tags.empty?
        return false unless append_lesson!(id, attrs)

        @registry[id] = attrs
        id
      end
    end

    private

    def next_id
      format('lesson_%03d', @registry.size + 1)
    end

    # 追加一条 lesson 存根：契约校验 → 试编译 → tmp → 原子 rename
    def append_lesson!(id, attrs)
      Doc.validate!(attrs)                       # 注释层设闸：白名单 key / 禁换行 / 长度上限
      content = File.exist?(@path) ? File.read(@path) : DEFAULT_HEADER
      content = content.chomp + "\n" unless content.end_with?("\n")
      block = attrs.map { |k, v| "# @doc #{k}: #{v}\n" }.join
      new_src = content + "#{block}def #{id}\nend\n"
      RubyVM::InstructionSequence.compile(new_src) # 代码层试编译
      tmp = "#{@path}.tmp"
      File.write(tmp, new_src)
      File.rename(tmp, @path)                    # 原子替换，不留 .tmp 残骸
      true
    rescue SyntaxError, StandardError => e
      warn "[Knowledge] 沉淀失败，已丢弃: #{e.message}"
      false
    end
  end
end