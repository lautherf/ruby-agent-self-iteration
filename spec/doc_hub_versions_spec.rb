# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 2：DocHub 多版本并行 —— 支撑「新旧版本并行验证」的核心场景。
#
# 契约（key 空间统一 String）：
#   hub.register(plugin)                  # 登记一个版本，并与既有版本并存
#   hub.get('name')                       # => 当前（最新）版本
#   hub.get('name', version: '1.0')       # => 指定版本
#   hub.mount('name', version: '1.0')     # 把指定版本切为当前版本（回滚语义）
#   hub.mount(plugin)                     # 兼容旧用法：等价于 register
class DocHubVersionsSpec < Minitest::Test
  include PluginFixture

  V1_SOURCE = <<~RUBY
    # @doc role: v1 原版
    def solve(a, b)
      a + b
    end
  RUBY

  V2_SOURCE = <<~RUBY
    # @doc role: v2 改版
    def solve(a, b)
      a + b + 1
    end
  RUBY

  # 同一插件名 'math' 的两个版本，各自独立文件
  def with_two_versions
    with_plugin_file(V1_SOURCE) do |path_v1|
      with_plugin_file(V2_SOURCE) do |path_v2|
        hub = RubyAgent::DocHub.new
        v1 = RubyAgent::DocPlugin.new('math', path_v1, version: '1.0')
        v2 = RubyAgent::DocPlugin.new('math', path_v2, version: '2.0')
        yield hub, v1, v2
      end
    end
  end

  def with_versions_of(pairs)
    raise ArgumentError, '需要至少一个版本' if pairs.empty?

    first, *rest = pairs
    with_plugin_file(first[:source]) do |path|
      hub = RubyAgent::DocHub.new
      plugin = RubyAgent::DocPlugin.new('math', path, version: first[:version])
      hub.register(plugin)
      yield hub, plugin, rest
    end
  end

  def test_register_keeps_two_versions_coexisting
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)

      assert_same v1, hub.get('math', version: '1.0')
      assert_same v2, hub.get('math', version: '2.0')
      assert_equal %w[1.0 2.0], hub.registry_for('math').sort
    end
  end

  def test_get_without_version_returns_latest
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)

      assert_same v2, hub.get('math')
      assert_equal '2.0', hub.get('math').version
    end
  end

  def test_get_returns_nil_for_unknown_name_or_version
    with_two_versions do |hub, v1, _v2|
      hub.register(v1)

      assert_nil hub.get('nope')
      assert_nil hub.get('nope', version: '1.0')
      assert_nil hub.get('math', version: '9.9')
    end
  end

  # 版本号必须按数值分段比较：字符串比较会误判 '1.0' > '10.0'
  def test_versions_compare_numerically_not_lexically
    with_plugin_file(DocHubVersionsSpec::V1_SOURCE) do |p1|
      with_plugin_file(DocHubVersionsSpec::V2_SOURCE) do |p10|
        hub = RubyAgent::DocHub.new
        hub.register(RubyAgent::DocPlugin.new('math', p1, version: '1.0'))
        hub.register(RubyAgent::DocPlugin.new('math', p10, version: '10.0'))

        assert_equal '10.0', hub.get('math').version
      end
    end
  end

  # 段缺失视为更小：'1.0' < '1.0.1'
  def test_versions_compare_handles_shorter_segments
    with_plugin_file(DocHubVersionsSpec::V1_SOURCE) do |pa|
      with_plugin_file(DocHubVersionsSpec::V2_SOURCE) do |pb|
        hub = RubyAgent::DocHub.new
        hub.register(RubyAgent::DocPlugin.new('math', pa, version: '1.0'))
        hub.register(RubyAgent::DocPlugin.new('math', pb, version: '1.0.1'))

        assert_equal '1.0.1', hub.get('math').version
      end
    end
  end

  def test_mount_switches_active_version_and_get_follows
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)

      rolled_back = hub.mount('math', version: '1.0') # 回滚到 v1

      assert_same v1, rolled_back
      assert_same v1, hub.get('math')
      assert_equal 'v1 原版', hub['math'].registry.dig('solve', 'role')
    end
  end

  def test_mount_without_version_resets_to_latest
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)
      hub.mount('math', version: '1.0')

      hub.mount('math') # 归位到最新

      assert_same v2, hub.get('math')
    end
  end

  def test_mount_returns_nil_for_unknown_version_without_breaking_active
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)

      assert_nil hub.mount('math', version: '9.9')
      assert_same v2, hub.get('math') # 未生效，当前版本保持 v2
    end
  end

  # 回滚后写入只落到活跃版本，另一版本不被污染 —— 「新旧并行」的核心保证
  def test_teach_and_for_llm_follow_active_version
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)
      hub.mount('math', version: '1.0')

      assert quietly { hub.teach('math', :solve, note: '写入活跃版本') }

      assert_equal '写入活跃版本', v1.registry.dig('solve', 'note')
      assert_nil v2.registry.dig('solve', 'note')
      assert_equal ['math'], hub.for_llm.map { |payload| payload[:plugin] }
    end
  end

  def test_register_via_mount_object_still_works
    with_plugin_file(DocHubVersionsSpec::V1_SOURCE) do |path|
      hub = RubyAgent::DocHub.new
      plugin = hub.mount(RubyAgent::DocPlugin.new('math', path))

      assert_equal 'math', plugin.name
      assert_equal 'math', hub['math'].name
      refute_empty hub['math'].registry
    end
  end

  def test_unmount_removes_every_version
    with_two_versions do |hub, v1, v2|
      hub.register(v1)
      hub.register(v2)

      hub.unmount('math')

      assert_nil hub.get('math')
      assert_nil hub.get('math', version: '1.0')
      assert_empty hub.plugins
    end
  end
end
