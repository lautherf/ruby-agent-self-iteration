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

  def test_apply_code_can_add_new_method_then_verify
    with_hub do |hub, path|
      agent = build_loop(hub, [
        "Action: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"add\",\"code\":\"def add(a, b)\\n  a + b\\nend\"}",
        "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"add\",\"args\":[2,3],\"expected\":5}",
        'Final Answer: done'
      ])

      assert quietly { agent.run('给数学插件新增加法') }

      assert_equal 'done', agent.state.answer
      assert_equal :verified, agent.state.code_changes.last[:status]
      assert_includes File.read(path), 'def add(a, b)', '新方法必须真实落盘'
      scope = RubyAgent::CodeEditor.new(path).scope
      assert_equal 5, Object.new.extend(scope).add(2, 3), '落盘后的新方法必须真实可执行'
    end
  end

  # —— 可编程验证器（泛化落地，三件套之一）——
  # verify 不再只有"单用例字符串相等"：批量 cases / raises 异常边界 / assert 布尔断言，
  # 让 Agent 能自己定义"什么算对"（如整除 0 该抛错、返回值必须为整数）。

  def test_verify_batch_cases_all_must_pass
    with_hub do |hub, _path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                        'code' => "def add(a, b)\n  a + b\nend" })

      outcome = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'add',
                                              'cases' => [{ 'args' => [1, 1], 'expected' => 2 },
                                                          { 'args' => [2, 3], 'expected' => 5 },
                                                          { 'args' => [-3, 4], 'expected' => 1 }] })

      assert_includes outcome, '验证通过(3 项)'
      assert_equal :verified, agent.state.code_changes.last[:status]
      assert agent.events.any? { |e| e[:type] == :verify && e[:ok] && e[:cases] == 3 }
    end
  end

  def test_verify_batch_failure_reports_wrong_case_and_rolls_back
    with_hub do |hub, path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                        'code' => "def add(a, b)\n  a - b\nend" })

      outcome = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'add',
                                              'cases' => [{ 'args' => [3, 2], 'expected' => 1 },
                                                          { 'args' => [5, 3], 'expected' => 8 }] })

      assert_includes outcome, '验证失败(1/2)'
      assert_includes outcome, '期望=8'
      assert_includes outcome, '实际=2'
      assert_includes outcome, '已自动回滚'
      assert_equal :rolled_back, agent.state.code_changes.last[:status]
      refute_includes File.read(path), 'a - b', '失败用例必须触发回滚'
    end
  end

  def test_verify_raises_form_covers_zero_division_boundary
    with_hub do |hub, path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'div',
                                        'code' => "def div(a, b)\n  a / b\nend" })

      good = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'div',
                                           'cases' => [{ 'args' => [6, 2], 'expected' => 3 },
                                                       { 'args' => [1, 0], 'raises' => 'ZeroDivisionError' }] })
      assert_includes good, '验证通过(2 项)', '除 0 边界可用 raises 验证'
      assert_equal :verified, agent.state.code_changes.last[:status]

      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'div',
                                        'code' => "def div(a, b)\n  0\nend" })
      bad = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'div',
                                          'cases' => [{ 'args' => [1, 0], 'raises' => 'ZeroDivisionError' }] })
      assert_includes bad, '验证失败(1/1)'
      assert_includes bad, '期望抛 ZeroDivisionError 但正常返回'
      assert_equal :rolled_back, agent.state.code_changes.last[:status]
      assert_includes File.read(path), 'a / b', '不抛错的实现被回滚，回到上一个已验证版本'
    end
  end

  def test_verify_assert_form_supports_computed_condition
    with_hub do |hub, _path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'half',
                                        'code' => "def half(n)\n  n / 2\nend" })

      good = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'half',
                                           'cases' => [{ 'args' => [10], 'expected' => 5 },
                                                       { 'args' => [7], 'assert' => 'result.is_a?(Integer)' }] })
      assert_includes good, '验证通过(2 项)'
      assert_includes good, '断言', '断言用例要留在回灌信息里'
      assert_equal :verified, agent.state.code_changes.last[:status]
    end
  end

  def test_verify_assert_failure_when_condition_false
    with_hub do |hub, path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'half',
                                        'code' => "def half(n)\n  n / 2\nend" })

      outcome = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'half',
                                              'cases' => [{ 'args' => [10], 'expected' => 5 },
                                                          { 'args' => [7], 'assert' => 'result.is_a?(Float)' }] })
      assert_includes outcome, '验证失败(1/2)'
      assert_includes outcome, '断言 result.is_a?(Float) 不成立'
      assert_equal :rolled_back, agent.state.code_changes.last[:status]
    end
  end

  # —— 权限分层（泛化三件套之二）——
  # 执行侧：verify 在独立子进程运行，恶意/写坏的 assert 只能炸 worker，主进程不崩溃。
  # 写侧：writable_plugins 白名单外插件只读不写（apply_code/teach/promote 落笔前强制校验）。

  def test_verify_isolates_malicious_assert_in_worker
    with_hub do |hub, path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                        'code' => "def add(a, b)\n  a + b\nend" })

      outcome = agent.invoke_tool('verify', { 'plugin' => 'math', 'method' => 'add',
                                              'cases' => [{ 'args' => [1, 1], 'assert' => 'exit!' }] })

      assert_includes outcome, '验证失败(1/1)', 'exit! 在旧实现里会杀掉测试进程；隔离后只是失败'
      assert_includes outcome, '隔离终止'
      assert_equal :rolled_back, agent.state.code_changes.last[:status], '逃逸验证照样回滚'
      content = File.read(path)
      assert_includes content, 'def solve(a, b)', '回滚删掉新增，插件文件回到原状'
      refute_includes content, 'def add', '主进程存活且磁盘被正确还原'
    end
  end

  def test_writable_whitelist_blocks_cross_plugin_writes
    with_hub do |hub, path|
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']),
                                       writable_plugins: ['ra'])

      error = assert_raises(StandardError) do
        agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'solve',
                                          'code' => "def solve(a, b)\n  a * 10\nend" })
      end
      assert_includes error.message, '无权写入插件 math'
      refute_includes File.read(path), 'a * 10', '白名单外的插件磁盘不得被改动'

      assert_raises(StandardError) do
        agent.invoke_tool('teach', { 'plugin' => 'math', 'method' => 'solve', 'note' => 'x' })
      end
      assert_raises(StandardError) do
        agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                          'code' => "def add(a, b)\n  a + b\nend" })
      end
    end
  end

  def test_writable_whitelist_allows_listed_plugin
    with_hub do |hub, _path|
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']),
                                       writable_plugins: %w[ra math])
      outcome = agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                                  'code' => "def add(a, b)\n  a + b\nend" })
      assert_includes outcome, '已应用新实现到 math#add'
    end
  end

  # —— 方法库管理（泛化三件套之三 · MVP）——
  # library 方法清单 + 重复定义闸门：AI 写库前先自查库存，同名 def 重复（历史污染）一律拒写。

  def test_library_tool_lists_methods_with_doc_and_duplicate_flag
    with_hub do |hub, _path|
      agent = build_loop(hub, ['Final Answer: ok'])
      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                        'code' => "def add(a, b)\n  a + b\nend" })
      agent.invoke_tool('teach', { 'plugin' => 'math', 'method' => 'add', 'role' => '加法' })

      listing = agent.invoke_tool('library', { 'plugin' => 'math' })
      assert_includes listing, '方法库 math·2 个方法', '库里有原始方法和新长得的方法'
      assert_includes listing, '- add（role=加法）'
      assert_includes listing, '- solve'
      refute_includes listing, '重复'
    end
  end

  def test_apply_code_rejects_when_method_previously_duplicated
    with_hub do |hub, path|
      # 手工制造历史污染：同名 def 出现两次（模拟文件被外部改坏/旧 bug）
      File.write(path, <<~RUBY)
        def solve(a, b)
          a + b
        end
        def solve(a, b)
          a - b
        end
      RUBY
      hub.mount(RubyAgent::DocPlugin.new('math', path))
      agent = build_loop(hub, ['Final Answer: ok'])

      error = assert_raises(StandardError) do
        agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'solve',
                                          'code' => "def solve(a, b)\n  a * 10\nend" })
      end
      assert_includes error.message, '重复定义'
      assert_includes error.message, 'library', '要让 AI 知道去哪自查'
      refute_includes File.read(path), 'a * 10', '重复污染下不得落盘'

      listing = agent.invoke_tool('library', { 'plugin' => 'math' })
      assert_includes listing, '重复'
      assert_includes listing, '重复×2'
    end
  end

  def test_apply_code_adds_method_when_unique_and_ignore_duplicate_of_other_names
    with_hub do |hub, _path|
      agent = build_loop(hub, ['Final Answer: ok'])
      outcome = agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'sub',
                                                  'code' => "def sub(a, b)\n  a - b\nend" })
      assert_includes outcome, '已应用新实现到 math#sub', '唯一的方法名照常追加'
    end
  end
end