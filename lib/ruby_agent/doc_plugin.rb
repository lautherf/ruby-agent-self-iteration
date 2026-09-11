# frozen_string_literal: true

require_relative 'doc'

module RubyAgent
  # DocPlugin —— 插件层：一个 .rb 文件 = 一个 DocPlugin。
  #
  # 与 Demo 的差异（均已修复）：
  #   - 缺口 1 修复：teach 入口统一 method.to_s，杜绝符号键/字符串键分裂。
  #   - 缺口 3 修复：合并时保留旧键（merge 语义），不再整体覆盖。
  class DocPlugin
    attr_reader :name, :path, :registry, :version

    def initialize(name, path, version: nil)
      @name = name.to_s
      @path = path
      @registry = {}
      @version = version.to_s if version
    end

    # 版本号按数值分段比较：'1.0' < '1.0.1' < '10.0'（非字典序）
    def self.compare_versions(a, b)
      pa = (a.to_s || '0').split('.').map(&:to_i)
      pb = (b.to_s || '0').split('.').map(&:to_i)
      max_len = [pa.length, pb.length].max
      while pa.length < max_len; pa << 0; end
      while pb.length < max_len; pb << 0; end
      pa <=> pb
    end

    # 内部：将版本号字符串拆分为整数数组，供 sort_by 使用
    def self._split_version(v)
      (v.to_s || '0').split('.').map(&:to_i)
    end

    # 加载：解析到局部变量，成功才替换（失败关闭，保留旧 registry）
    def load!
      parsed = Doc.parse(@path)
      @registry = parsed
      self
    rescue StandardError => e
      warn "[#{@name}] 加载失败，保留旧版: #{e.message}"
      self
    end

    # 写回：内存先改 → 落盘成功才保留 → 失败观察等价恢复
    def teach(method, **spec)
      key = method.to_s                                  # 缺口 1 修复
      old = @registry[key]&.dup                          # 缺口 3 修复：留旧值用于回滚
      merged = (@registry[key] || {}).merge(spec.transform_keys(&:to_s)) # 缺口 3 修复：保留旧键
      @registry[key] = merged

      ok = Doc.commit(@path, key, merged)
      @registry[key] = old unless ok                     # 观察等价恢复
      ok
    end

    def for_llm
      { plugin: @name, methods: @registry }
    end

    # 热重载：mtime 变就重新 load（按插件粒度）
    def watch(interval: 0.3)
      Thread.new do
        last = File.mtime(@path)
        loop do
          sleep interval
          now = File.mtime(@path)
          next if now == last

          last = now
          load!
          warn "[#{@name}] 检测到变更，已重载"
        end
      end
    end
  end
end
