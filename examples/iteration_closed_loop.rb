# frozen_string_literal: true

# Sprint 5 闭环演示：三步自我迭代，处处离线（MockLLM），复现 README 成功标准 #5 #6。
#
# 运行：ruby -Ilib examples/iteration_closed_loop.rb

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# —— 1. 造一个 math 插件 ——
Dir.mktmpdir('demo') do |dir|
  math_path = File.join(dir, 'math.rb')
  File.write(math_path, <<~RUBY)
    # @doc role: 先加后减，求最终答案
    def solve(a, b)
      a + b
    end
  RUBY

  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('math', math_path))

  # —— 2. 经验仓库 ——
  knowledge = RubyAgent::Knowledge.new(File.join(dir, 'lessons.rb'))
  puts "== 知识仓库空: #{knowledge.lessons.empty?}"

  # —— 3. 迭代闭环：每轮结束把经验沉淀，下一轮自动注入 ——
  #    每轮的 Agent 模拟「使用工具 + 沉淀经验」的行为（MockLLM 决定了执行轨迹）。
  lessons_learned = []
iteration = RubyAgent::IterationLoop.new(
  hub: hub,
  knowledge: knowledge,
  builder: proc do
      RubyAgent::AgentLoop.new(
        hub: hub,
        llm: RubyAgent::MockLLM.new([
          "Action: learn\nAction Input: {\"lesson\": \"任务完成：Math 插件可行\"}",
          'Final Answer: 完成'
        ]),
        knowledge: knowledge
      )
    end
  )

  results = iteration.run(%w[迭代一 迭代二 迭代三])
  puts '== 每轮结果:'
  results.each { |r| puts "  #{r.task}: status=#{r.status} answer=#{r.answer}" }

  puts '== 沉淀的经验（持久化到 lessons.rb）:'
  knowledge.load!
  knowledge.lessons.each { |l| puts "  #{l[:id]}: #{l[:note]}" }

  puts '== 下一轮 Agent 的 system prompt 是否读到了经验:'
  system = iteration.agents.last.llm.calls.first[:messages].find { |m| m[:role] == 'system' }[:content]
  system.lines.grep(/knowledge/).each { |l| puts "  #{l.strip}" }

  puts "== 闭环成立? #{system.include?('任务完成')}"
end