# frozen_string_literal: true

require 'thread'

module RubyAgent
  # CodeEditor —— 代码级编辑：定位单个方法 → 整体替换 def..end → 试编译 → 原子落盘。
  #
  # 与 Doc（只改 `# @doc` 注释）互补：Doc 管"元数据"，CodeEditor 管"方法体"。
  #
  # 安全设计（对齐核心原则）：
  #   - 方法名强校验：新代码必须定义同名方法，杜绝"换了个方法"。
  #   - 代码层设闸：整文件 RubyVM 试编译，过不了不落盘（失败关闭）。
  #   - 原子提交：tmp + rename，不留半截状态。
  #   - 快照栈：每次成功替换压栈，rollback! 按次恢复（可逆副作用）。
  #   - 作用域隔离：scope 用匿名 Module 求值，调用新实现零全局污染。
  class CodeEditor
    attr_reader :path

    def initialize(path)
      @path = path
      @snapshots = []
      @mutex = Mutex.new
    end

    # 当前文件中定义的方法名列表（按出现顺序）
    def methods
      lines = File.readlines(@path)
      lines.filter_map { |l| l[DEF_CAPTURE_RE, 1] }
    end

    # 读取单个方法源码（def .. end，含首尾行）；不存在返回 nil
    def read_method(method)
      @mutex.synchronize do
        span = self.class.method_span(File.readlines(@path), method)
        return nil unless span

        lines = File.readlines(@path)
        lines[span[0]..span[1]].join.sub(/\n\z/, '')
      end
    end

    # 整体替换方法体。成功返回 true 并压入快照（可回滚）；失败返回 false 且磁盘不变。
    def replace(method, new_source)
      src = new_source.to_s
      return false if src.strip.empty?
      return false unless src =~ self.class.def_re(method)   # 必须定义同名方法

      @mutex.synchronize do
        lines = File.readlines(@path)
        span = self.class.method_span(lines, method)
        return false unless span

        head, tail = span
        new_lines = src.lines.map { |l| l.end_with?("\n") ? l : "#{l}\n" }
        next_src = (lines[0...head] + new_lines + lines[(tail + 1)..]).join
        RubyVM::InstructionSequence.compile(next_src)        # 代码层试编译
        write_atomic(next_src)
        @snapshots << { method: method.to_s, span: span, source: lines[head..tail] }
        true
      end
    rescue SyntaxError, StandardError => e
      warn "[CodeEditor] #{File.basename(@path)} 替换失败，已丢弃: #{e.message}"
      false
    end

    # 在文件末尾追加一个新方法（区别于 replace，replace 只改已存在方法）。
    # ra 借此能"长出"新能力：新增方法追加在文件末，同样先试编译再原子落盘，
    # 快照的 source 记为 nil，rollback! 时对应删除该追加段。
    def add(method, new_source)
      src = new_source.to_s
      return false if src.strip.empty?
      return false unless src =~ self.class.def_re(method)   # 必须定义同名方法
      return false if read_method(method)                   # 已存在时用 replace，不重复追加

      @mutex.synchronize do
        lines = File.readlines(@path)
        lines << "\n" unless lines.empty? || lines.last.end_with?("\n")
        head = lines.size
        new_lines = src.lines.map { |l| l.end_with?("\n") ? l : "#{l}\n" }
        next_src = (lines + new_lines).join
        RubyVM::InstructionSequence.compile(next_src)        # 代码层试编译
        write_atomic(next_src)
        @snapshots << { method: method.to_s, span: [head, head + new_lines.size - 1], source: nil }
        true
      end
    rescue SyntaxError, StandardError => e
      warn "[CodeEditor] #{File.basename(@path)} 新增失败，已丢弃: #{e.message}"
      false
    end

    # 回滚最近一次替换（恢复快照里的旧代码 / 删除新增段），空栈幂等返回 false。
    def rollback!
      @mutex.synchronize do
        snap = @snapshots.pop
        return false unless snap

        lines = File.readlines(@path)
        head, tail = snap[:span]
        if snap[:source].nil?
          lines.slice!(head..tail)                           # 新增段：直接删除
        else
          lines[head..tail] = snap[:source]                  # 替换段：恢复旧代码
        end
        next_src = lines.join
        RubyVM::InstructionSequence.compile(next_src)
        write_atomic(next_src)
        true
      end
    rescue SyntaxError, StandardError => e
      warn "[CodeEditor] #{File.basename(@path)} 回滚失败: #{e.message}"
      false
    end

    # 当前文件源码的隔离作用域（匿名 Module）：
    # 实例方法 `Object.new.extend(scope).solve(...)`，类方法 `scope.solve(...)`。
    def scope
      mod = Module.new
      mod.module_eval(File.read(@path), @path, 1)
      mod
    end

    def pending?
      !@snapshots.empty?
    end

    # 定位 def 行与其专属 end 的 [start, end] 行号区间。
    # def 行的缩进决定 end 的归属（嵌套块缩进更深），配合整文件试编译兜底。
    def self.method_span(lines, method)
      re = def_re(method)
      start = lines.index { |l| l =~ re }
      return nil unless start

      indent = lines[start][/^\s*/]
      idx = start + 1
      while idx < lines.length
        l = lines[idx]
        if l[/^\s*/] == indent && l.strip == 'end'
          return [start, idx]
        end
        idx += 1
      end
      nil
    end

    # 匹配 `def name` / `def name(` / `def self.name` / `def name!(` 等方法名形态
    def self.def_re(method)
      esc = Regexp.escape(method.to_s)
      /^\s*def\s+(?:(?:self|Klass)\.)?#{esc}(?:\s|\()/
    end

    private

    DEF_CAPTURE_RE = /^\s*def\s+(?:(?:self|Klass)\.)?(\w+[\?!=]?)/

    def write_atomic(src)
      tmp = "#{@path}.tmp"
      File.write(tmp, src)
      File.rename(tmp, @path)
    end
  end
end