# frozen_string_literal: true

require_relative 'ruby_agent/doc'
require_relative 'ruby_agent/doc_plugin'
require_relative 'ruby_agent/doc_hub'
require_relative 'ruby_agent/dynamic_methods'
require_relative 'ruby_agent/refinements'
require_relative 'ruby_agent/llm_adapter'
require_relative 'ruby_agent/code_editor'
require_relative 'ruby_agent/agent_loop'
require_relative 'ruby_agent/deepseek_adapter'
require_relative 'ruby_agent/knowledge'
require_relative 'ruby_agent/memory'
require_relative 'ruby_agent/iteration'

module RubyAgent
  # ra 的身份常量：名字 / 版本 / 口号。
  # 完整自我的描述不硬编码在这里，而是作为「身份契约」写在 plugins/ra.rb，
  # 与 ra 认识其他插件共用同一套 `# @doc` 机制 —— 一切皆插件，ra 自己也是插件。
  NAME   = 'ra'
  VERSION = '0.6.0'
  MOTTO  = '循环往复，持续进化，永不崩盘。'

  # ra 身份契约所在文件
  RA_PLUGIN_PATH = File.expand_path('../plugins/ra.rb', __dir__)

  class << self
    # 把 ra 自己挂上 DocHub：从此 ra 能通过 for_llm / whoami 读到"我是谁"。
    def mount_ra!(hub)
      hub.mount(DocPlugin.new(NAME, RA_PLUGIN_PATH).load!)
    end

    # 延迟加载 Zeitwerk：仅在真正需要自动加载时才 require，
    # 使核心组件可在无 bundler / zeitwerk 的环境下独立使用与测试。
    def loader
      @loader ||= begin
        require 'zeitwerk'
        Zeitwerk::Loader.new.tap do |loader|
          loader.push_dir(File.expand_path('lib', __dir__))
          loader.push_dir(File.expand_path('plugins', __dir__))
          loader.inflector = Zeitwerk::Inflector.new
          loader.setup
        end
      end
    end

    def doc_hub
      @doc_hub ||= DocHub.new
    end
  end
end
