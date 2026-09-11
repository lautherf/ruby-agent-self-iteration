# frozen_string_literal: true

require_relative 'ruby_agent/doc'
require_relative 'ruby_agent/doc_plugin'
require_relative 'ruby_agent/doc_hub'
require_relative 'ruby_agent/dynamic_methods'
require_relative 'ruby_agent/refinements'
require_relative 'ruby_agent/llm_adapter'
require_relative 'ruby_agent/agent_loop'
require_relative 'ruby_agent/deepseek_adapter'

module RubyAgent
  class << self
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
