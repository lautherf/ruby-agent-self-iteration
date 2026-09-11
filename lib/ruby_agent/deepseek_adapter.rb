# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'llm_adapter'

module RubyAgent
  # DeepSeekAdapter —— 把 DeepSeek 的 Chat Completions 接成 LLMAdapter。
  #
  # transport 可注入，测试时传假对象即可完全离线；
  # 默认实现是 Net::HTTP。
  class DeepSeekAdapter < LLMAdapter
    DEFAULT_BASE_URL = 'https://api.deepseek.com'
    DEFAULT_MODEL    = 'deepseek-chat'

    # 基于 Net::HTTP 的默认传输层
    class HTTPTransport
      def initialize(timeout: 60)
        @timeout = timeout
      end

      def post(url:, headers:, body:)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = @timeout
        http.open_timeout = @timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| request[k] = v }
        request.body = body

        response = http.request(request)
        Response.new(response.code.to_i, response.body.to_s)
      end
    end

    Response = Struct.new(:status, :body)

    attr_reader :base_url, :model, :last_usage

    def initialize(api_key:, model: DEFAULT_MODEL, base_url: DEFAULT_BASE_URL,
                   transport: nil, timeout: 60, max_retries: 1, retry_wait: 0.5)
      super()
      raise ArgumentError, 'api_key 不能为空' if api_key.nil? || api_key.to_s.empty?

      @api_key = api_key.to_s
      @model = model
      @base_url = base_url.to_s.chomp('/')
      @transport = transport || HTTPTransport.new(timeout: timeout)
      @max_retries = max_retries
      @retry_wait = retry_wait
      @last_usage = nil
    end

    def streaming?
      true
    end

    # 同步补全：返回助手回复正文
    def chat(messages, **opts)
      response = perform(request_payload(messages, opts, stream: false))
      data = parse_json(response.body)
      @last_usage = data['usage'] if data['usage']
      extract_content(data)
    end

    # 流式补全：逐块回调增量文本，返回拼接结果
    def chat_stream(messages, **opts, &on_chunk)
      response = perform(request_payload(messages, opts, stream: true))
      buffer = +''
      response.body.to_s.each_line do |line|
        delta = parse_sse_line(line)
        next if delta.nil?

        buffer << delta
        on_chunk&.call(delta)
      end
      buffer
    end

    def inspect
      "#<#{self.class} model=#{@model} base_url=#{@base_url} api_key=[FILTERED]>"
    end

    private

    def request_payload(messages, opts, stream:)
      payload = {
        'model' => opts[:model] || @model,
        'messages' => normalize_messages(messages),
        'stream' => stream
      }
      payload['temperature'] = opts[:temperature] if opts.key?(:temperature)
      payload['max_tokens'] = opts[:max_tokens] if opts.key?(:max_tokens)
      payload
    end

    def normalize_messages(messages)
      Array(messages).map do |message|
        message.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      end
    end

    def endpoint
      "#{@base_url}/chat/completions"
    end

    def headers
      {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{@api_key}"
      }
    end

    # 带重试的请求：传输异常与 5xx 会重试，其余状态码交给 validate!
    def perform(payload)
      body = JSON.generate(payload)
      last_error = nil

      (0..@max_retries).each do |attempt|
        response =
          begin
            @transport.post(url: endpoint, headers: headers, body: body)
          rescue StandardError => e
            last_error = TransportError.new("DeepSeek 传输失败: #{e.class}: #{e.message}")
            wait_before_retry(attempt)
            next
          end

        if response.status >= 500 && attempt < @max_retries
          last_error = TransportError.new("DeepSeek 服务端错误: #{response.status}")
          wait_before_retry(attempt)
          next
        end

        validate!(response)
        return response
      end

      raise last_error || TransportError.new('DeepSeek 请求失败')
    end

    def wait_before_retry(attempt)
      return unless @retry_wait.to_f.positive?

      sleep(@retry_wait.to_f * (attempt + 1))
    end

    def validate!(response)
      return if response.status.between?(200, 299)

      raise APIError, "DeepSeek API 返回 #{response.status}: #{truncate(response.body)}"
    end

    def parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError => e
      raise APIError, "DeepSeek 响应不是合法 JSON: #{e.message}"
    end

    def extract_content(data)
      content = data.dig('choices', 0, 'message', 'content')
      raise APIError, "DeepSeek 响应缺少 choices/message/content: #{truncate(JSON.generate(data))}" if content.nil?

      content
    end

    # 解析一行 SSE；非 data 行、[DONE]、无增量内容都返回 nil
    def parse_sse_line(line)
      line = line.to_s.strip
      return nil unless line.start_with?('data:')

      data = line.sub(/\Adata:\s*/, '')
      return nil if data.empty? || data == '[DONE]'

      parsed = parse_json(data)
      if (err = parsed['error'])
        message = err.is_a?(Hash) ? err['message'] : err.to_s
        raise APIError, "DeepSeek 流式返回错误: #{message}"
      end

      @last_usage = parsed['usage'] if parsed['usage']
      parsed.dig('choices', 0, 'delta', 'content')
    end

    def truncate(text, limit = 200)
      text = text.to_s
      text.length > limit ? "#{text[0, limit]}..." : text
    end
  end
end
