# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 6 · 阶段 2：代码级自修改闭环
#
# 闭环 = 成功标准 #3「安全地应用修改，失败自动回滚」在"代码层"落地：
#   apply_code（应用新方法体）→ verify（跑真实求值验证）
#     → 失败自动 rollback 并回灌 observation → Agent 重试 → 验证通过 → :verified
class CodeLoopSpec < Minitest::Test
  include PluginFixture

  def with_hub
    with_plugin_file do |path|
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', path))
      yield hub, path
    end
  end

  def build_loop(hub, responses, **opts)
    RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(responses), **opts)
  end

  def test_read_code_tool_exposes_current_source
    with_hub do |hub, _path|
      agent = build_loop(hub, ['Final Answer: ok'])

      src = agent.invoke_tool('read_code', { 'plugin' => 'math', 'method' => 'solve' })

      assert_equal "def solve(a, b)\n  a + b\nend", src
    end
  end

  def test_apply_code_then_verify_success_marks_verified
    with_hub do |hub, path|
      agent = build_loop(hub, [
        "Action: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a * 10\\nend\"}",
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[2,3],\"expected\":20}",
        'Final Answer: done'
      ])

      assert quietly { agent.run('把 solve 改成乘以 10') }

      assert_equal :done, agent.state.status
      assert_equal :verified, agent.state.code_changes.last[:status]
      assert_equal 1, agent.events.count { |e| e[:type] == :code_change }
      assert_equal 1, agent.events.count { |e| e[:type] == :verify && e[:ok] }
      assert_includes File.read(path), 'a * 10'
    end
  end

  def test_verify_failure_auto_rolls_back_and_retry_succeeds
    with_hub do |hub, path|
      agent = build_loop(hub, [
        # 第一次：改成减法（错误），验证失败 → 自动回滚
        "Thought: 改成减法\nAction: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a - b\\nend\"}",
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[1,2],\"expected\":3}",
        # 看到"已自动回滚"的 observation，重试正确实现
        "Thought: 减法不对，改成加法\nAction: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a + b\\nend\"}",
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[1,2],\"expected\":3}",
        'Final Answer: 修正完成'
      ])

      assert quietly { agent.run('把 solve 修正为返回正确结果') }

      assert_equal '修正完成', agent.state.answer
      assert_equal 4, agent.state.steps.size

      statuses = agent.state.code_changes.map { |c| c[:status] }
      assert_includes statuses, :rolled_back, '错误实现必须被自动回滚'
      assert_equal :verified, agent.state.code_changes.last[:status], '最终实现必须已验证'

      # 失败验证的 observation 必须告知"已自动回滚"，供 Agent 下次决策
      failed_obs = agent.state.steps[1].observation
      assert_includes failed_obs, '验证失败'
      assert_includes failed_obs, '已自动回滚'

      # 磁盘最终回到正确实现
      assert_includes File.read(path), 'a + b'
      refute_includes File.read(path), 'a - b'

      assert_equal 1, agent.events.count { |e| e[:type] == :rollback }
    end
  end

  def test_syntax_error_apply_is_captured_as_observation_and_loop_continues
    with_hub do |hub, path|
      agent = build_loop(hub, [
        "Action: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a + b\"}",
        'Final Answer: done'
      ])

      assert quietly { agent.run('t') }

      assert_equal 'done', agent.state.answer
      assert_includes agent.state.steps.first.observation, '替换失败'
      content = File.read(path)
      assert_includes content, 'a + b'
      refute_includes content, 'a * b', '语法错误时磁盘必须保持原样'
      assert_empty agent.state.code_changes.select { |c| c[:status] == :applied }
    end
  end

  def test_verify_unknown_method_emits_error_observation
    with_hub do |hub, _path|
      agent = build_loop(hub, [
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"nope\",\"args\":[],\"expected\":1}",
        'Final Answer: done'
      ])

      assert quietly { agent.run('t') }

      assert_includes agent.state.steps.first.observation, 'NoMethodError'
    end
  end

  def test_async_apply_before_verify_is_registered_for_rollback
    with_hub do |hub, path|
      agent = build_loop(hub, [
        "Action: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a * 5\\nend\"}",
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[1,1],\"expected\":2}",
        'Final Answer: done'
      ])

      agent.run('t')

      assert agent.events.any? { |e| e[:type] == :rollback }
      assert_equal false, File.read(path).include?('a * 5')
    end
  end
end