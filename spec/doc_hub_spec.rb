# frozen_string_literal: true

require_relative 'spec_helper'

class DocHubSpec < Minitest::Test
  include PluginFixture

  def build_hub(path, name = 'math')
    hub = RubyAgent::DocHub.new
    hub.mount(RubyAgent::DocPlugin.new(name, path))
    hub
  end

  def test_mount_loads_plugin_and_exposes_it_by_name
    with_plugin_file do |path|
      hub = build_hub(path)

      refute_nil hub['math']
      assert_equal 'math', hub['math'].name
    end
  end

  def test_unmount_removes_plugin
    with_plugin_file do |path|
      hub = build_hub(path)
      hub.unmount('math')

      assert_nil hub['math']
    end
  end

  def test_for_llm_aggregates_all_plugins
    with_plugin_file do |path|
      hub = build_hub(path, 'math')

      payload = hub.for_llm
      assert_equal 1, payload.size
      assert_equal 'math', payload.first[:plugin]
    end
  end

  def test_teach_routes_to_named_plugin
    with_plugin_file do |path|
      hub = build_hub(path)

      assert quietly { hub.teach('math', :solve, note: 'hub 写入') }
      assert_equal 'hub 写入', hub['math'].registry.dig('solve', 'note')
    end
  end

  def test_teach_returns_false_for_unknown_plugin
    with_plugin_file do |path|
      hub = build_hub(path)

      refute hub.teach('nope', :solve, note: 'x')
    end
  end
end
