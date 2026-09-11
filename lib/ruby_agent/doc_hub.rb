# frozen_string_literal: true

require_relative 'doc_plugin'

module RubyAgent
  # DocHub —— 中枢层：挂载/卸载、按名寻址、新旧版本并行、读/写分离。
  #
  # 读（for_llm）= 汇总所有插件的知识；写（teach）= 定向到某个插件。
  class DocHub
    attr_reader :plugins

    def initialize(_loader = nil)
      @plugins = {}
    end

    def mount(plugin)
      @plugins[plugin.name] = plugin
      plugin.load!
      plugin
    end

    def unmount(name)
      @plugins.delete(name.to_s)
    end

    def [](name)
      @plugins[name.to_s]
    end

    # LLM 读：汇总所有插件
    def for_llm
      @plugins.values.map(&:for_llm)
    end

    # LLM 写：定向到某个插件
    def teach(plugin_name, method, **spec)
      plugin = @plugins[plugin_name.to_s] or return false

      plugin.teach(method, **spec)
    end

    # 广播热重载
    def watch_all(**options)
      @plugins.each_value { |plugin| plugin.watch(**options) }
    end
  end
end
