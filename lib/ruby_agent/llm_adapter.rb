# frozen_string_literal: true

module RubyAgent
  # LLMAdapter —— 模型调用抽象层。
  #
  # Agent Loop 只依赖本接口，不关心背后是 mock、DeepSeek 还是别的服务；
  # 这样 ReAct 循环可以在无网络的沙箱里被完整测试。
  class LLMAdapter
    # 通用错误基类
    class Error < StandardError; end
    # 服务端返回了非预期响应（4xx/5xx、结构异常等）
    class APIError < Error; end
    # 传输层失败（超时、连接被拒、DNS 等）
    class TransportError < Error; end

    # 同步补全。返回字符串（模型回复正文）。
    def chat(_messages, **_opts)
      raise NotImplementedError, "#{self.class} 必须实现 #chat"
    end

    # 流式补全。逐块把增量文本交给 block；返回拼接后的完整文本。
    def chat_stream(_messages, **_opts, &_on_chunk)
      raise NotImplementedError, "#{self.class} 必须实现 #chat_stream"
    end

    # 本适配器是否支持流式
    def streaming?
      false
    end
  end

  # MockLLM —— 预置响应队列的适配器。
  #
  # 队列里的每一项要么是字符串回复，要么是一个异常实例（抛出用）。
  # 每次 #chat 记录一次调用，便于断言提示词内容。
  class MockLLM < LLMAdapter
    attr_reader :calls

    def initialize(responses)
      super()
      @responses = Array(responses).dup
      @calls = []
    end

    def chat(messages, **opts)
      @calls << { messages: messages, opts: opts }
      response = @responses.shift
      raise APIError, 'MockLLM 响应队列已耗尽' if response.nil?
      raise response if response.is_a?(Exception)

      response.to_s
    end

    def streaming?
      true
    end

    # 把预置回复按行切块吐出，模拟流式
    def chat_stream(messages, **opts, &on_chunk)
      text = chat(messages, **opts)
      chunks = []
      text.each_line do |line|
        chunks << line
        on_chunk&.call(line)
      end
      chunks.join
    end

    # 尚未消费的响应数
    def remaining
      @responses.size
    end
  end
end
