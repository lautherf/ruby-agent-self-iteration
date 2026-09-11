# frozen_string_literal: true

require_relative 'spec_helper'

class DocPluginSpec < Minitest::Test
  include PluginFixture

  def test_load_reads_registry_from_file
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!

      assert_equal 'math', plugin.name
      assert_equal({ 'solve' => { 'role' => '先加后减，求最终答案' } }, plugin.registry)
    end
  end

  def test_teach_persists_to_disk_and_returns_true
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!

      assert quietly { plugin.teach(:solve, note: '新增说明') }
      assert_includes File.read(path), '# @doc note: 新增说明'
      assert_includes File.read(path), '# @doc role: 先加后减，求最终答案'
    end
  end

  def test_teach_rolls_back_in_memory_when_commit_fails
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!
      before = plugin.registry['solve'].dup

      refute quietly { plugin.teach(:solve, note: "bad\nvalue") }
      assert_equal before, plugin.registry['solve'], '落盘失败时必须观察等价地回滚'
    end
  end

  def test_load_keeps_old_registry_when_file_is_unreadable
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!
      before = plugin.registry.dup

      File.delete(path)
      plugin.load!

      assert_equal before, plugin.registry, '加载失败必须保留旧 registry'
    end
  end

  def test_for_llm_exposes_plugin_knowledge
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!

      payload = plugin.for_llm
      assert_equal 'math', payload[:plugin]
      assert_equal '先加后减，求最终答案', payload[:methods]['solve']['role']
    end
  end

  def test_watch_reloads_when_file_changes
    with_plugin_file do |path|
      plugin = RubyAgent::DocPlugin.new('math', path).load!
      thread = plugin.watch(interval: 0.05)

      sleep 0.15
      File.write(path, <<~RUBY)
        # @doc role: 更新后的角色
        def solve(a, b)
          a + b
        end
      RUBY

      deadline = Time.now + 2
      sleep 0.05 while plugin.registry.dig('solve', 'role') != '更新后的角色' && Time.now < deadline

      assert_equal '更新后的角色', plugin.registry.dig('solve', 'role')
    ensure
      thread&.kill
    end
  end
end
