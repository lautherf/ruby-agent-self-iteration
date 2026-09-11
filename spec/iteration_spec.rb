# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 5 · 阶段 2：迭代闭环（IterationLoop）
#
# 闭环验证 = 成功标准 #5「把这次经验写回知识库」+ #6「下一次迭代从更新后的知识出发」。
class IterationLoopSpec < Minitest::Test
  include PluginFixture

  def with_knowledge_file
    Dir.mktmpdir('ruby-agent-iteration') do |dir|
      yield File.join(dir, 'lessons.rb')
    end
  end

  def test_next_iteration_reads_previous_lesson_in_system_prompt
    with_knowledge_file do |kb_path|
      hub = RubyAgent::DocHub.new
      loop_ = RubyAgent::IterationLoop.new(
        hub: hub,
        builder: proc { RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok'])) },
        knowledge: RubyAgent::Knowledge.new(kb_path),
        reflect: ->(state) { [{ lesson: "任务 #{state.task} 的经验" }] }
      )

      loop_.run(['第一次任务', '第二次任务'])

      second_agent = loop_.agents.last
      system = second_agent.llm.calls.first[:messages].find { |m| m[:role] == 'system' }[:content]
      assert_includes system, '第一次任务 的经验', '第二轮必须读到第一轮沉淀的经验'
    end
  end

  def test_returns_per_task_results
    with_knowledge_file do |kb_path|
      hub = RubyAgent::DocHub.new
      loop_ = RubyAgent::IterationLoop.new(
        hub: hub,
        builder: proc { RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: 42'])) },
        knowledge: RubyAgent::Knowledge.new(kb_path),
        reflect: ->(_state) { [] }
      )

      results = loop_.run(%w[a b])

      assert_equal 2, results.size
      assert_equal 'a', results[0].task
      assert_equal '42', results[0].answer
      assert_equal :done, results[0].status
    end
  end

  def test_reflect_hook_sediments_lesson_into_knowledge
    with_knowledge_file do |kb_path|
      knowledge = RubyAgent::Knowledge.new(kb_path)
      loop_ = RubyAgent::IterationLoop.new(
        hub: RubyAgent::DocHub.new,
        builder: proc { RubyAgent::AgentLoop.new(hub: RubyAgent::DocHub.new, llm: RubyAgent::MockLLM.new(['Final Answer: ok'])) },
        knowledge: knowledge,
        reflect: ->(state) { [{ lesson: "prefer #{state.status}" }] }
      )

      loop_.run(['t'])

      assert_equal 1, knowledge.lessons.size
      assert_equal 'prefer done', knowledge.lessons.first[:note]
    end
  end

  def test_default_reflect_consumes_agent_learned_lessons
    with_knowledge_file do |kb_path|
      math_path = write_math_plugin
      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', math_path))
      knowledge = RubyAgent::Knowledge.new(kb_path)

      loop_ = RubyAgent::IterationLoop.new(
        hub: hub,
        builder: proc do
          RubyAgent::AgentLoop.new(
            hub: hub,
            llm: RubyAgent::MockLLM.new([
              "Action: learn\nAction Input: {\"lesson\": \"先看文档再动手\"}",
              'Final Answer: ok'
            ]),
            knowledge: knowledge
          )
        end,
        knowledge: knowledge
      )

      loop_.run(['沉淀自己学到的'])

      assert_equal '先看文档再动手', knowledge.lessons.first[:note]
    end
  end

  def test_agent_loop_learn_tool_emits_event_and_tracks_state
    with_knowledge_file do |kb_path|
      knowledge = RubyAgent::Knowledge.new(kb_path)
      agent = RubyAgent::AgentLoop.new(
        hub: RubyAgent::DocHub.new,
        llm: RubyAgent::MockLLM.new([
          "Action: learn\nAction Input: {\"lesson\": \"经验-A\", \"tags\": \"sprint5\"}",
          'Final Answer: done'
        ]),
        knowledge: knowledge
      )

      learned = []
      agent.on(:learn) { |e| learned << e }

      assert quietly { agent.run('t') }

      assert_equal 'done', agent.state.answer
      assert_equal 1, agent.state.learned.size
      assert_equal '经验-A', agent.state.learned.first[:lesson]
      assert_equal 1, learned.size
      assert_equal 'sprint5', learned.first[:tags]
    end
  end

  def test_agent_loop_learn_tool_rejects_empty_lesson
    with_knowledge_file do |kb_path|
      agent = RubyAgent::AgentLoop.new(
        hub: RubyAgent::DocHub.new,
        llm: RubyAgent::MockLLM.new([
          "Action: learn\nAction Input: {\"lesson\": \"   \"}",
          'Final Answer: done'
        ]),
        knowledge: RubyAgent::Knowledge.new(kb_path)
      )

      agent.run('t')

      assert_includes agent.state.steps.first.observation, '不能为空'
    end
  end

  private

  def write_math_plugin
    dir = Dir.mktmpdir('ruby-agent-math')
    path = File.join(dir, 'math.rb')
    File.write(path, <<~RUBY)
      # @doc role: 先加后减，求最终答案
      def solve(a, b)
        a + b
      end
    RUBY
    path
  end
end