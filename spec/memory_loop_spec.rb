# frozen_string_literal: true

require_relative 'spec_helper'

# Memory 的 AgentLoop / IterationLoop 集成（Sprint 7）。
# 闭环：remember 显式记忆 + run 后自动沉淀 → 记忆插件挂载进 for_llm → 下一轮注入 →
#       IterationLoop 每轮把老对话折叠成 lesson（遗忘 = 重构）。
class MemoryLoopSpec < Minitest::Test
  include PluginFixture

  def build_memory
    Dir.mktmpdir('memy') { |dir| yield RubyAgent::Memory.new(File.join(dir, 'memory.rb')) }
  end

  def test_remember_tool_writes_turn_and_emits_event
    build_memory do |memory|
      hub = RubyAgent::DocHub.new
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']), memory: memory)
      captured = []
      agent.on(:remember) { |e| captured << e }

      text = agent.invoke_tool('remember', { 'who' => 'user', 'note' => '记住我喜欢 Ruby', 'tags' => 'pref' })

      assert_includes text, 'turn_001'
      assert_equal ['记住我喜欢 Ruby'], memory.load!.turns.map { |t| t[:note] }
      assert_equal 1, captured.size
      assert_equal :remember, captured.first[:type]
    end
  end

  def test_auto_records_this_conversation_after_run
    build_memory do |memory|
      hub = RubyAgent::DocHub.new
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: 完成']), memory: memory)

      assert quietly { agent.run('把 solve 改成加法') }

      turns = memory.load!.turns
      assert_equal 1, turns.size, 'run 结束必须自动沉淀一次对话'
      assert_includes turns.first[:note], '把 solve 改成加法', '对话必须含用户任务'
      assert_includes turns.first[:note], '完成', '对话必须含 ra 的答复'
    end
  end

  def test_auto_record_collapses_multiline_task_to_single_line_turn
    build_memory do |memory|
      hub = RubyAgent::DocHub.new
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: 完成']), memory: memory)

      agent.run("第一行\n第二行\n第三行")

      turn = memory.load!.turns.first
      refute_nil turn, '多行任务也必须能写入记忆'
      refute_includes turn[:note], "\n", '注释契约禁止换行：自动沉淀必须压平'
      assert_includes turn[:note], '第一行'
      assert RubyVM::InstructionSequence.compile(File.read(memory.path))
    end
  end

  def test_remember_tool_accepts_tags_array
    build_memory do |memory|
      hub = RubyAgent::DocHub.new
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']), memory: memory)

      agent.invoke_tool('remember', { 'who' => 'user', 'note' => '风格偏好', 'tags' => ['style', 'pref'] })

      turn = memory.load!.turns.first
      assert_equal 'style,pref', turn[:tags], '数组 tags 应归一化为逗号分隔字符串'
    end
  end

  def test_read_memory_recalls_context
    build_memory do |memory|
      hub = RubyAgent::DocHub.new
      memory.add_turn(who: 'user', note: '之前讨论过数学内化', tags: 'math')
      memory.add_turn(who: 'user', note: '今天聊点别的', tags: 'chat')
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']), memory: memory)

      hits = agent.invoke_tool('read_memory', { 'query' => '数学' })

      assert_includes hits, '之前讨论过数学内化'
      refute_includes hits, '今天聊点别的'
    end
  end

  def test_memory_plugin_mount_injects_turns_into_system_prompt
    build_memory do |memory|
      memory.add_turn(who: 'user', note: '记忆注入验证', tags: 't')
      hub = RubyAgent::DocHub.new
      hub.mount(memory.plugin.load!)
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']))

      agent.run('你是谁')

      system = agent.llm.calls.first[:messages].find { |m| m[:role] == 'system' }[:content]
      assert_includes system, '记忆注入验证', '记忆经 for_llm 注入 system prompt'
    end
  end

  def test_iteration_loop_folds_old_turns_each_round
    Dir.mktmpdir('iter') do |dir|
      hub = RubyAgent::DocHub.new
      knowledge = RubyAgent::Knowledge.new(File.join(dir, 'lessons.rb'))
      memory = RubyAgent::Memory.new(File.join(dir, 'memory.rb'))
      4.times { |i| memory.add_turn(who: 'user', note: "旧对话 #{i}", tags: 'old') }

      iteration = RubyAgent::IterationLoop.new(
        hub: hub, knowledge: knowledge, memory: memory, memory_keep: 2,
        summarize: ->(batch) { "折叠了 #{batch.size} 条旧对话" },
        builder: proc do
          RubyAgent::AgentLoop.new(hub: hub, knowledge: knowledge, memory: memory,
                                   llm: RubyAgent::MockLLM.new(['Final Answer: 好']))
        end
      )

      iteration.run(['第一轮'])

      assert_equal 2, memory.turns.size, '老对话被折叠，只留最近窗口'
      assert_includes memory.lessons.map { |l| l[:note] }.join, '折叠了 3 条旧对话'
      assert hub.get('memory'), '记忆必须挂载进 DocHub'
    end
  end

  def test_iteration_mounts_memory_and_latest_round_reads_it
    Dir.mktmpdir('iter2') do |dir|
      hub = RubyAgent::DocHub.new
      knowledge = RubyAgent::Knowledge.new(File.join(dir, 'lessons.rb'))
      memory = RubyAgent::Memory.new(File.join(dir, 'memory.rb'))
      agent = nil

      iteration = RubyAgent::IterationLoop.new(
        hub: hub, knowledge: knowledge, memory: memory,
        builder: proc do
          agent = RubyAgent::AgentLoop.new(
            hub: hub, knowledge: knowledge, memory: memory,
            llm: RubyAgent::MockLLM.new(['Final Answer: 第二轮答案'])
          )
        end
      )

      iteration.run(%w[第一轮任务 第二轮任务])

      turns = memory.load!.turns.map { |t| t[:note] }.join
      assert_equal 2, memory.turns.size
      assert_includes turns, '第一轮任务'
      assert_includes turns, '第二轮任务'
      assert agent
    end
  end
end