# frozen_string_literal: true

require_relative 'spec_helper'

# ra —— 项目 Agent 的身份与自明能力。
#
# 设计契约：ra 认识的"自己"，不是硬编码，而是和它认识任何插件一样 ——
# 一份写在 plugins/ra.rb 里的 `# @doc` 身份契约。mount 到 DocHub 后，
# ra 通过自己的 for_llm（或者 whoami 工具）就能"读到我是谁"。
# 这就是「一切皆插件」的极致：ra 自己也是一个插件。
class RaSpec < Minitest::Test
  RA_PLUGIN = File.expand_path('../plugins/ra.rb', __dir__)

  def test_ra_self_plugin_parses_identity_from_doc_contract
    plugin = RubyAgent::DocPlugin.new('ra', RA_PLUGIN).load!

    intro = plugin.registry['self_intro']
    assert_equal 'ra', plugin.name
    assert_includes intro['role'], 'ra', '身份契约必须声明自己是 ra'
    assert_equal RubyAgent::MOTTO, intro['motto']
  end

  def test_ra_self_plugin_describes_capabilities_and_limits
    plugin = RubyAgent::DocPlugin.new('ra', RA_PLUGIN).load!

    assert_includes plugin.registry['self_intro']['params'], 'list_docs'
    assert_includes plugin.registry['self_intro']['params'], 'apply_code'
    assert_includes plugin.registry['what_i_learned']['role'], '知识沉淀'
    assert_includes plugin.registry['what_i_must_not']['role'], '禁止'
  end

  def test_mount_ra_makes_ra_self_aware_via_for_llm
    hub = RubyAgent::DocHub.new
    RubyAgent.mount_ra!(hub)

    docs = hub.for_llm
    ra = docs.find { |d| d[:plugin] == 'ra' }
    refute_nil ra, 'mount_ra! 必须把 ra 挂上 DocHub'
    assert_equal 'ra', ra[:plugin]
  end

  def test_agent_system_prompt_carries_ra_identity
    hub = RubyAgent::DocHub.new
    RubyAgent.mount_ra!(hub)
    agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']))

    agent.run('你是谁')

    system = agent.llm.calls.first[:messages].find { |m| m[:role] == 'system' }[:content]
    assert_includes system, 'ra'
    assert_includes system, RubyAgent::MOTTO, 'ra 必须能在系统提示里读到自己的口号'
    assert_includes system, '我是 ra', '身份契约内容必须进入 system prompt'
  end

  def test_whoami_tool_returns_ra_identity
    hub = RubyAgent::DocHub.new
    RubyAgent.mount_ra!(hub)
    agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']))

    text = agent.invoke_tool('whoami', {})

    assert_includes text, 'ra'
    assert_includes text, RubyAgent::MOTTO
  end
end