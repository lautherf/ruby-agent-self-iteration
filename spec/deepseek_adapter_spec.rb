# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/ruby_agent/llm_adapter'
require_relative '../lib/ruby_agent/deepseek_adapter'

# DeepSeek Adapter 的接口形状 / 请求构造 / 错误分支测试。
# 全程使用假 transport，绝不发真实网络请求。
class DeepSeekAdapterSpec < Minitest::Test
  FakeResponse = Struct.new(:status, :body)
  FakeTransport = Struct.new(:responses, :requests) do
    def post(url:, headers:, body:)
      requests << { url: url, headers: headers, body: body }
      item = responses.shift
      raise item if item.is_a?(Exception)
      raise 'FakeTransport 已无更多响应' if item.nil?

      item
    end
  end

  def build(responses, **opts)
    transport = FakeTransport.new([*responses], [])
    adapter = RubyAgent::DeepSeekAdapter.new(
      api_key: 'sk-test', transport: transport, retry_wait: 0, **opts
    )
    [adapter, transport]
  end

  def json_response(hash, status: 200)
    FakeResponse.new(status, JSON.generate(hash))
  end

  def chat_payload(content, usage: nil)
    body = { 'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => content } }] }
    body['usage'] = usage if usage
    json_response(body)
  end

  def sse_response(*lines)
    FakeResponse.new(200, lines.map { |l| "data: #{l}\n" }.join + "\n")
  end

  def delta(text)
    JSON.generate('choices' => [{ 'delta' => { 'content' => text } }])
  end

  def test_requires_api_key
    assert_raises(ArgumentError) { RubyAgent::DeepSeekAdapter.new(api_key: nil) }
    assert_raises(ArgumentError) { RubyAgent::DeepSeekAdapter.new(api_key: '') }
  end

  def test_defaults
    adapter, = build([])
    assert_equal 'deepseek-chat', adapter.model
    assert_equal 'https://api.deepseek.com', adapter.base_url
    assert adapter.streaming?
    assert_kind_of RubyAgent::LLMAdapter, adapter
  end

  def test_chat_posts_to_endpoint_with_auth_and_payload
    adapter, transport = build([chat_payload('你好')])
    adapter.chat([{ role: 'system', content: 's' }, { role: 'user', content: 'u' }])

    request = transport.requests.first
    assert_equal 'https://api.deepseek.com/chat/completions', request[:url]
    assert_equal 'Bearer sk-test', request[:headers]['Authorization']
    assert_equal 'application/json', request[:headers]['Content-Type']

    body = JSON.parse(request[:body])
    assert_equal 'deepseek-chat', body['model']
    assert_equal false, body['stream']
    assert_equal [{ 'role' => 'system', 'content' => 's' }, { 'role' => 'user', 'content' => 'u' }],
                 body['messages']
  end

  def test_chat_returns_content_and_records_usage
    usage = { 'prompt_tokens' => 5, 'completion_tokens' => 7, 'total_tokens' => 12 }
    adapter, = build([chat_payload('最终答案', usage: usage)])
    assert_equal '最终答案', adapter.chat([{ role: 'user', content: 'u' }])
    assert_equal usage, adapter.last_usage
  end

  def test_chat_raises_api_error_on_error_status
    adapter, = build([FakeResponse.new(401, '{"error":"invalid key"}')])
    error = assert_raises(RubyAgent::LLMAdapter::APIError) do
      adapter.chat([{ role: 'user', content: 'u' }])
    end
    assert_includes error.message, '401'
  end

  def test_chat_raises_api_error_on_malformed_body
    adapter, = build([FakeResponse.new(200, 'not-json')])
    assert_raises(RubyAgent::LLMAdapter::APIError) { adapter.chat([{ role: 'user', content: 'u' }]) }
  end

  def test_chat_raises_api_error_when_choices_missing
    adapter, = build([json_response({ 'id' => 'x' })])
    error = assert_raises(RubyAgent::LLMAdapter::APIError) { adapter.chat([{ role: 'user', content: 'u' }]) }
    assert_includes error.message, 'choices'
  end

  def test_chat_raises_transport_error_when_transport_fails
    adapter, = build([IOError.new('connection refused')], max_retries: 0)
    error = assert_raises(RubyAgent::LLMAdapter::TransportError) do
      adapter.chat([{ role: 'user', content: 'u' }])
    end
    assert_includes error.message, 'connection refused'
  end

  def test_chat_retries_transport_failure_then_succeeds
    adapter, transport = build([IOError.new('timeout'), chat_payload('重试成功')])
    assert_equal '重试成功', adapter.chat([{ role: 'user', content: 'u' }])
    assert_equal 2, transport.requests.size
  end

  def test_chat_retries_5xx_then_succeeds
    adapter, transport = build([FakeResponse.new(503, 'busy'), chat_payload('好了')])
    assert_equal '好了', adapter.chat([{ role: 'user', content: 'u' }])
    assert_equal 2, transport.requests.size
  end

  def test_chat_gives_up_after_max_retries
    adapter, transport = build([IOError.new('timeout')], max_retries: 2)
    assert_raises(RubyAgent::LLMAdapter::TransportError) { adapter.chat([{ role: 'user', content: 'u' }]) }
    assert_equal 3, transport.requests.size
  end

  def test_chat_stream_yields_deltas_and_returns_full_text
    adapter, transport = build([sse_response(delta('你'), delta('好'), '[DONE]')])
    chunks = []
    result = adapter.chat_stream([{ role: 'user', content: 'u' }]) { |c| chunks << c }

    assert_equal '你好', result
    assert_equal %w[你 好], chunks
    assert_equal true, JSON.parse(transport.requests.first[:body])['stream']
  end

  def test_chat_stream_skips_blank_and_non_data_lines
    body = "event: ping\n\ndata: #{delta('A')}\n\n: keep-alive\n\ndata: [DONE]\n\n"
    adapter, = build([FakeResponse.new(200, body)])
    chunks = []
    assert_equal 'A', adapter.chat_stream([{ role: 'user', content: 'u' }]) { |c| chunks << c }
    assert_equal ['A'], chunks
  end

  def test_chat_stream_raises_api_error_on_error_payload
    adapter, = build([sse_response(JSON.generate('error' => { 'message' => '额度不足' }))])
    error = assert_raises(RubyAgent::LLMAdapter::APIError) do
      adapter.chat_stream([{ role: 'user', content: 'u' }]) { |_c| }
    end
    assert_includes error.message, '额度不足'
  end

  def test_error_hierarchy_is_shared
    assert_operator RubyAgent::DeepSeekAdapter, :<, RubyAgent::LLMAdapter
    assert_operator RubyAgent::LLMAdapter::APIError, :<, RubyAgent::LLMAdapter::Error
    assert_operator RubyAgent::LLMAdapter::TransportError, :<, RubyAgent::LLMAdapter::Error
  end

  def test_inspect_masks_api_key
    adapter, = build([])
    refute_includes adapter.inspect, 'sk-test'
  end
end
