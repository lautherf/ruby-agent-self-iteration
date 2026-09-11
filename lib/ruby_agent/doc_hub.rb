# frozen_string_literal: true

require_relative 'doc_plugin'

module RubyAgent
  # DocHub —— 中枢层：挂载/卸载、按名寻址、新旧版本并行、读/写分离。
  #
  # 读（for_llm）= 汇总所有插件的知识；写（teach）= 定向到某个插件。
  #
  # 多版本存储结构：
  #   @plugins = { name => { _active => plugin, version => plugin, ... } }
  class DocHub
    attr_reader :plugins

    def initialize(_loader = nil)
      @plugins = {}
    end

    # 注册插件：如果同名已有版本，按版本号数值比较决定是否替换活跃版本
    def register(plugin)
      return plugin if plugin.nil?
      versions = (@plugins[plugin.name] ||= {})
      versions[:_active] = plugin unless versions[:_active]
      prev_active = versions[:_active]
      if prev_active.version.nil? || DocPlugin.compare_versions(plugin.version, prev_active.version) > 0
        versions[:_active] = plugin
      end
      versions[plugin.version] = plugin
      plugin.load! if plugin.registry.empty?
      plugin
    end

    # 挂载（兼容旧用法 mount(plugin) + 新用法 mount(name, version:)）
    def mount(plugin_or_name, version: nil)
      if plugin_or_name.is_a?(DocPlugin)
        register(plugin_or_name)
      else
        if version
          active = get(plugin_or_name.to_s, version: version)
          return nil if active.nil?
          versions = @plugins[plugin_or_name.to_s] or return nil
          versions[:_active] = active
          active
        else
          # 不带 version：归位到最新版本（按版本号数值比较）
          versions = @plugins[plugin_or_name.to_s] or return nil
          latest = versions.keys.reject { |k| k == :_active }.map(&:to_s).sort_by { |v| DocPlugin.send(:_split_version, v) }.last
          return nil if latest.nil?
          active = versions[latest]
          versions[:_active] = active
          active
        end
      end
    end

    # 卸载：移除该插件名下的所有版本
    def unmount(name)
      @plugins.delete(name.to_s)
    end

    # 按名访问当前活跃版本（兼容 [] 语法）
    def [](name)
      get(name.to_s)
    end

    # 按名+版本查找插件
    # 不传 version => 活跃版本；传 version => 严格匹配，找不到返回 nil
    def get(name, version: nil)
      versions = @plugins[name.to_s] or return nil
      if version
        versions[version.to_s]
      else
        versions[:_active]
      end
    end

    # 返回某插件名下所有已注册版本号（不含 _active 元数据 key）
    def registry_for(name)
      versions = @plugins[name.to_s] or return []
      versions.keys.reject { |k| k == :_active }.map(&:to_s).sort
    end

    # LLM 读：汇总所有插件的活跃版本
    def for_llm
      @plugins.values.map { |v| v[:_active]&.for_llm }.compact
    end

    # LLM 写：定向到某个插件的活跃版本
    def teach(plugin_name, method, **spec)
      plugin = get(plugin_name.to_s) or return false
      plugin.teach(method, **spec)
    end

    # 广播热重载
    def watch_all(**options)
      @plugins.each_value do |versions|
        versions[:_active]&.watch(**options)
      end
    end
  end
end
