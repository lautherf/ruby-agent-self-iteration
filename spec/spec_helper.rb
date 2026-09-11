# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# 测试夹具：在临时目录里生成一个插件文件，测试结束后自动清理。
module PluginFixture
  DEFAULT_SOURCE = <<~RUBY
    # @doc role: 先加后减，求最终答案
    def solve(a, b)
      a + b
    end
  RUBY

  def with_plugin_file(source = DEFAULT_SOURCE)
    dir = Dir.mktmpdir('ruby-agent-spec')
    path = File.join(dir, 'plugin_under_test.rb')
    File.write(path, source)
    yield path
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  # 吞掉组件内部的 warn 噪音，返回块的返回值
  def quietly
    result = nil
    capture_io { result = yield }
    result
  end
end
