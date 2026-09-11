# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 4 · 阶段 1（基础 Loop）+ 阶段 2（DocHub 集成）
class AgentLoopSpec < Minitest::Test
  include PluginFixture

  def build_loop(responses, hub: RubyAgent::DocHub.new, **opts)
    RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(responses), **opts)
  end

  # ---------- 阶段 1：ReAct 循环 ----------

  def test_react_loop_executes_tool_then_returns_final_answer
    agent = build_loop([
      "Thought: 先看看有哪些文档\nAction: list_docs\nAction Input: {}",
      "Thought: 看完了\nFinal Answer: 共 0 个插件"
    ])

    answer = agent.run('列出文档')

    assert_equal '共 0 个插件', answer
    assert agent.state.finished?
    assert_equal 1, agent.state.steps.size
    assert_equal 'list_docs', agent.state.steps.first.action
    assert_equal '先看看有哪些文档', agent.state.steps.first.thought
  end

  def test_loop_appends_observation_to_next_prompt
    agent = build_loop([
      "Action: list_docs\nAction Input: {}",
      "Final Answer: done"
    ])

    agent.run('go')

    second_prompt = agent.llm.calls.last[:messages].map { |m| m[:content] }.join("\n")
    assert_includes second_prompt, 'Observation:'
    assert_includes second_prompt, 'list_docs'
  end

  def test_custom_tool_receives_parsed_json_input
    got = []
    agent = build_loop([
      "Action: echo\nAction Input: {\"msg\": \"hi\", \"n\": 2}",
      "Final Answer: ok"
    ])
    agent.register_tool('echo') do |input|
      got << input
      "echo:#{input['msg']}x#{input['n']}"
    end

    agent.run('t')

    assert_equal({ 'msg' => 'hi', 'n' => 2 }, got.first)
    assert_includes agent.state.steps.first.observation, 'echo:hix2'
  end

  def test_unknown_tool_yields_error_observation_and_loop_continues
    agent = build_loop([
      "Action: nope\nAction Input: {}",
      "Final Answer: 放弃"
    ])

    agent.run('t')

    assert_equal '放弃', agent.state.answer
    assert_includes agent.state.steps.first.observation, '未知工具'
    assert_equal 2, agent.llm.calls.size
  end

  def test_tool_exception_is_captured_as_observation
    agent = build_loop([
      "Action: boom\nAction Input: {}",
      "Final Answer: ok"
    ])
    agent.register_tool('boom') { |_i| raise '炸了' }

    agent.run('t')

    assert_includes agent.state.steps.first.observation, '炸了'
    assert agent.state.finished?
  end

  def test_stops_at_max_steps_without_final_answer
    agent = build_loop(["Action: list_docs\nAction Input: {}"] * 4, max_steps: 2)

    agent.run('t')

    assert_equal :max_steps, agent.state.status
    assert_equal 2, agent.state.steps.size
  end

  def test_llm_error_is_recorded_and_stops_loop
    agent = build_loop([RubyAgent::LLMAdapter::APIError.new('boom')])

    agent.run('t')

    assert_equal :error, agent.state.status
    assert_includes agent.state.error, 'boom'
    assert_empty agent.state.steps
  end

  def test_emits_lifecycle_events
    agent = build_loop([
      "Action: list_docs\nAction Input: {}",
      "Final Answer: ok"
    ])

    seen = []
    agent.on { |e| seen << e[:type] }
    agent.on(:tool_call) { |e| seen << "tool:#{e[:tool]}" }

    agent.run('t')

    assert_includes seen, :start
    assert_includes seen, :llm_response
    assert_includes seen, 'tool:list_docs'
    assert_includes seen, :observation
    assert_includes seen, :finish
    assert_includes agent.events.map { |e| e[:type] }, :finish
  end

  def test_events_are_recorded_with_payload
    agent = build_loop(['Final Answer: 42'])

    agent.run('t')

    finish_events = agent.events.select { |e| e[:type] == :finish }
    assert_equal 1, finish_events.size
    assert_equal '42', finish_events.first[:answer]
  end

  # ---------- 阶段 2：DocHub 集成 ----------

  def test_run_loads_plugins_from_hub_into_state
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('greeting', path))
      agent = build_loop(['Final Answer: ok'], hub: hub)

      agent.run('t')

      assert_includes agent.state.plugins, 'greeting'
    end
  end

  def test_system_prompt_carries_hub_knowledge
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', path))
      agent = build_loop(['Final Answer: ok'], hub: hub)

      agent.run('t')

      system = agent.llm.calls.first[:messages].find { |m| m[:role] == 'system' }[:content]
      assert_includes system, 'math'
      assert_includes system, '先加后减'
    end
  end

  def test_sync_reflects_newly_mounted_plugin
    agent = build_loop(['Final Answer: ok'])

    with_plugin_file do |path|
      agent.hub.mount(RubyAgent::DocPlugin.new('late', path))
      agent.sync!

      assert_includes agent.state.plugins, 'late'
    end
  end

  def test_sync_hot_reloads_plugin_content_from_disk
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('plugin', path))
      agent = build_loop(['Final Answer: ok'], hub: hub)

      rewrite_plugin_file(path, role: 'v2')
      agent.sync!

      assert_equal 'v2', hub['plugin'].registry.dig('solve', 'role')
      assert_includes agent.events.map { |e| e[:type] }, :synced
    end
  end

  def test_teach_tool_round_trips_through_hub
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', path))
      agent = build_loop([
        "Action: teach\nAction Input: {\"plugin\": \"math\", \"method\": \"solve\", \"note\": \"来自工具\"}",
        'Final Answer: ok'
      ], hub: hub)

      assert quietly { agent.run('t') }
      assert_equal '来自工具', hub['math'].registry.dig('solve', 'note')
      refute hub['math'].registry.dig('solve', 'role').nil?
    end
  end

  def test_read_docs_tool_exposes_hub_knowledge
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', path))
      agent = build_loop(['Final Answer: ok'], hub: hub)

      value = agent.invoke_tool('read_docs', {})

      assert_equal 1, value.size
      assert_equal 'math', value.first[:plugin]
    end
  end

  private

  def rewrite_plugin_file(path, **attrs)
    body = attrs.map { |k, v| "# @doc #{k}: #{v}" }.join("\n")
    File.write(path, "#{body}\ndef solve(a, b)\n  a + b\nend\n")
  end
end
