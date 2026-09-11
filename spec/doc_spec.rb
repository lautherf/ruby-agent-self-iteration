# frozen_string_literal: true

require_relative 'spec_helper'

# Doc：解析 / 改写 / 提交，以及注释层校验。
class DocSpec < Minitest::Test
  include PluginFixture

  def test_parse_reads_doc_block_above_def
    with_plugin_file do |path|
      assert_equal({ 'solve' => { 'role' => '先加后减，求最终答案' } }, RubyAgent::Doc.parse(path))
    end
  end

  def test_parse_always_returns_string_keys
    with_plugin_file do |path|
      RubyAgent::Doc.parse(path).each_key { |k| assert_instance_of String, k }
    end
  end

  def test_parse_ignores_plain_comments
    with_plugin_file(<<~RUBY) do |path|
      # 这是普通注释
      # @doc role: 有契约的
      def solve(a, b)
        a + b
      end
    RUBY
      assert_equal({ 'solve' => { 'role' => '有契约的' } }, RubyAgent::Doc.parse(path))
    end
  end

  def test_validate_rejects_unknown_key
    error = assert_raises(RubyAgent::Doc::ValidationError) do
      RubyAgent::Doc.validate!(evil: 'x')
    end
    assert_match(/非法注释键/, error.message)
  end

  def test_validate_rejects_newline_in_value
    assert_raises(RubyAgent::Doc::ValidationError) do
      RubyAgent::Doc.validate!(note: "ok\nend\n$$$ = 1")
    end
  end

  def test_validate_rejects_overlong_value
    assert_raises(RubyAgent::Doc::ValidationError) do
      RubyAgent::Doc.validate!(note: 'x' * (RubyAgent::Doc::MAX_VALUE_LEN + 1))
    end
  end

  def test_validate_accepts_whitelisted_single_line_value
    assert RubyAgent::Doc.validate!(role: '先加后减', syntax: 'def solve(a, b)')
  end

  def test_commit_replaces_existing_doc_block
    with_plugin_file do |path|
      assert RubyAgent::Doc.commit(path, 'solve', 'role' => '新的角色')

      assert_equal({ 'solve' => { 'role' => '新的角色' } }, RubyAgent::Doc.parse(path))
      assert_equal 1, File.read(path).lines.count { |l| l.include?('@doc') }
      refute File.exist?("#{path}.tmp"), '临时文件必须已被 rename 掉'
    end
  end

  def test_commit_rejects_broken_code
    with_plugin_file(<<~RUBY) do |path|
      # @doc role: x
      def solve(a, b)
        a +
      end
    RUBY
      before = File.read(path)
      refute quietly { RubyAgent::Doc.commit(path, 'solve', 'role' => 'y') }
      assert_equal before, File.read(path)
    end
  end

  def test_commit_returns_false_when_method_missing
    with_plugin_file do |path|
      refute quietly { RubyAgent::Doc.commit(path, 'nope', 'role' => 'x') }
    end
  end
end
