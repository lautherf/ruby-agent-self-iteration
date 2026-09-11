# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 6 · 阶段 1：CodeEditor 代码级编辑
class CodeEditorSpec < Minitest::Test
  include PluginFixture

  DUAL_SOURCE = <<~RUBY
    # @doc role: 先加后减，求最终答案
    def solve(a, b)
      a + b
    end

    # @doc role: 乘法
    def self.mult(a, b)
      a * b
    end
  RUBY

  def test_read_method_returns_current_source
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      src = editor.read_method(:solve)
      assert_equal "def solve(a, b)\n  a + b\nend", src
    end
  end

  def test_read_method_returns_nil_when_missing
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      assert_nil editor.read_method(:nope)
    end
  end

  def test_read_method_handles_self_method
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      assert_equal "def self.mult(a, b)\n  a * b\nend", editor.read_method(:mult)
    end
  end

  def test_list_methods
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      assert_equal %w[solve mult], editor.methods
    end
  end

  def test_replace_updates_method_body_and_keeps_doc_comment
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      assert editor.replace(:solve, "def solve(a, b)\n  a * b\nend")

      assert_equal "def solve(a, b)\n  a * b\nend", editor.read_method(:solve)
      assert_includes File.read(path), "# @doc role: 先加后减，求最终答案", 'doc 注释必须原样保留'
    end
  end

  def test_replace_rejects_wrong_method_name
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      before = File.read(path)

      refute quietly { editor.replace(:solve, "def other(a, b)\n  a * b\nend") }
      assert_equal before, File.read(path), '方法名不匹配时不得落盘'
    end
  end

  def test_replace_rejects_syntax_error
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      before = File.read(path)

      refute quietly { editor.replace(:solve, 'def solve(a, b)') }
      assert_equal before, File.read(path), '语法错误时不得落盘'
    end
  end

  def test_replace_leaves_no_tmp_file
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      editor.replace(:solve, "def solve(a, b)\n  a - b\nend")

      refute Dir.glob("#{path}.tmp").any?, '原子替换后不得残留 .tmp'
    end
  end

  def test_scope_invokes_replaced_method_isolated
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      editor.replace(:solve, "def solve(a, b)\n  a - b\nend")

      scope = editor.scope
      obj = Object.new.extend(scope)

      assert_equal(-1, obj.solve(1, 2), 'scope 必须反映新实现')
      assert_equal 6, scope.mult(3, 2), '同文件其他方法不受影响'
      refute Object.new.respond_to?(:solve), '全局方法表不得被污染'
    end
  end

  def test_rollback_restores_previous_source
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      editor.replace(:solve, "def solve(a, b)\n  a * b\nend")

      assert editor.rollback!

      assert_equal "def solve(a, b)\n  a + b\nend", editor.read_method(:solve)
      obj = Object.new.extend(editor.scope)
      assert_equal 3, obj.solve(1, 2), '回滚后 scope 恢复旧实现'
    end
  end

  def test_rollback_is_stack_like_and_idempotent
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      editor.replace(:solve, "def solve(a, b)\n  a * 10\nend")
      editor.replace(:solve, "def solve(a, b)\n  a * 100\nend")

      assert editor.rollback!
      assert_equal "def solve(a, b)\n  a * 10\nend", editor.read_method(:solve)
      assert editor.rollback!
      assert_equal "def solve(a, b)\n  a + b\nend", editor.read_method(:solve)
      assert_equal false, quietly { editor.rollback! }, '空栈回滚应幂等返回 false'
    end
  end

  def test_replace_multiple_methods_without_bonus_edits
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)
      editor.replace(:mult, "def self.mult(a, b)\n  a + b\nend")

      assert_equal "def self.mult(a, b)\n  a + b\nend", editor.read_method(:mult)
      assert_equal "def solve(a, b)\n  a + b\nend", editor.read_method(:solve)
    end
  end

  def test_concurrent_replace_does_not_corrupt_file
    with_plugin_file(DUAL_SOURCE) do |path|
      editor = RubyAgent::CodeEditor.new(path)

      threads = 6.times.map do |i|
        Thread.new { quietly { editor.replace(:solve, "def solve(a, b)\n  a + #{i}\nend") } }
      end
      threads.each(&:join)

      assert editor.rollback!, '替换后必须可整体回滚（并发期间文件保持可编译）'
      assert RubyVM::InstructionSequence.compile(File.read(path))
    end
  end
end