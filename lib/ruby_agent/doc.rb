# frozen_string_literal: true

module RubyAgent
  # Doc —— 核心层，只做三件事：parse / rewrite_lines / commit。
  #
  # 「注释即契约」：`# @doc key: value` 是唯一的持久化格式。
  # 与 Demo 的差异（均已修复，见 docs/doc-demo-review.md）：
  #   - 缺口 2 修复：写入前对**注释层**做校验（key 白名单 / 值不得含换行 / 长度上限）。
  #     原 Demo 只对代码做试编译，注释是 LLM 的写入通道却零校验。
  module Doc
    DOC_LINE = /^\s*#\s*@doc\s+(\w+):\s*(.*)$/

    # 允许写入的注释键白名单（缺口 2 修复；Sprint 7 加入 who=对话发言人）
    ALLOWED_KEYS = %w[role note example syntax params returns since deprecated tags motto who].freeze

    # 单条注释值长度上限（缺口 2 修复）
    MAX_VALUE_LEN = 500

    class ValidationError < StandardError; end

    class << self
      # —— 解析：从文件读出 method => {attr => value} ——
      # 键统一为 String（与 teach / commit 的键空间保持一致）
      def parse(path)
        registry = {}
        pending = {}
        File.foreach(path) do |line|
          case line
          when DOC_LINE
            pending[$1] = $2.strip
          when /^\s*def\s+(\w+)/
            registry[$1] = pending.dup unless pending.empty?
            pending = {}
          when /^\s*#/, /^\s*$/
            # 普通注释/空行，保留 pending
          else
            pending = {}
          end
        end
        registry
      end

      # —— 生成：把 attrs 写成注释块，插到 def 上方 ——
      def rewrite_lines(path, method, attrs)
        src = File.readlines(path)
        def_i = src.index { |l| l =~ /^\s*def\s+#{Regexp.escape(method.to_s)}\b/ }
        return nil unless def_i

        # 往上吃掉已有的 @doc 注释块
        start = def_i
        start -= 1 while start > 0 && src[start - 1] =~ DOC_LINE
        indent = src[def_i][/^\s*/]
        block = attrs.map { |k, v| "#{indent}# @doc #{k}: #{v}\n" }
        src[start...def_i] = block
        src.join
      end

      # —— 注释层校验（缺口 2 修复）：注释是 LLM 的写入通道，必须独立设闸 ——
      def validate!(attrs)
        attrs.each do |k, v|
          key = k.to_s
          raise ValidationError, "非法注释键: #{key}" unless ALLOWED_KEYS.include?(key)

          value = v.to_s
          raise ValidationError, "注释值包含换行，会破坏文件结构: #{key}" if value.include?("\n")
          raise ValidationError, "注释值过长(>#{MAX_VALUE_LEN}): #{key}" if value.length > MAX_VALUE_LEN
        end
        true
      end

      # —— 提交：注释校验 → 试编译 → 临时文件 → 原子 rename ——
      # 任一步失败都返回 false 且**不落盘**（失败关闭）。
      def commit(path, method, attrs)
        method = method.to_s                        # 缺口 1 修复：键空间统一
        attrs = attrs.transform_keys(&:to_s)
        validate!(attrs)                            # 缺口 2 修复：注释层设闸

        new_src = rewrite_lines(path, method, attrs)
        return false unless new_src

        RubyVM::InstructionSequence.compile(new_src) # 代码层语法校验
        tmp = "#{path}.tmp"
        File.write(tmp, new_src)
        File.rename(tmp, path)                       # 原子替换
        true
      rescue SyntaxError, StandardError => e
        warn "[Doc] 写回失败，已丢弃: #{e.message}"
        false
      end
    end
  end
end
