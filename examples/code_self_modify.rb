# frozen_string_literal: true

# Sprint 6 演示：代码级自修改闭环 —— apply → verify → 失败自动回滚 → 重试成功。
#
# 全程离线（MockLLM）。模拟 Agent 两次尝试：
#   第 1 次把 solve 改成减法 → verify(1,2)→3 失败 → 自动回滚 + observation 回灌
#   第 2 次改成加法     → verify 通过 → :verified，磁盘固化正确实现
#
# 运行：ruby -Ilib examples/code_self_modify.rb

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

Dir.mktmpdir('code-demo') do |dir|
  path = File.join(dir, 'math.rb')
  File.write(path, <<~RUBY)
    # @doc role: 先加后减，求最终答案
    def solve(a, b)
      a + b
    end
  RUBY

  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('math', path))

  agent = RubyAgent::AgentLoop.new(
    hub: hub,
    llm: RubyAgent::MockLLM.new([
      "Thought: 改成减法\nAction: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a - b\\nend\"}",
      "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[1,2],\"expected\":3}",
      "Thought: 减法不对（会自动回滚），改成加法\nAction: apply_code\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"code\":\"def solve(a, b)\\n  a + b\\nend\"}",
      "Action: verify\nAction Input: {\"plugin\":\"math\",\"method\":\"solve\",\"args\":[1,2],\"expected\":3}",
      'Final Answer: 修正完成'
    ])
  )

  agent.on(:code_change) { |e| puts "  → code_change: #{e[:plugin]}##{e[:method]} = #{e[:status]}" }
  agent.on(:rollback)    { |e| puts "  → rollback: #{e[:plugin]}##{e[:method]}" }
  agent.on(:verify)      { |e| puts "  → verify: #{e[:plugin]}##{e[:method]} ok=#{e[:ok]} actual=#{e[:actual]}" }

  answer = agent.run('把 solve 修正为返回正确结果')
  puts "答案: #{answer}"

  puts '== 审计轨迹:'
  agent.state.code_changes.each { |c| puts "  #{c[:plugin]}##{c[:method]} → #{c[:status]}" }

  puts '== 失败验证的 observation（回灌给 LLM）:'
  failed = agent.state.steps.find { |s| s.observation.to_s.include?('验证失败') }
  puts "  #{failed.observation}"

  puts "== 磁盘最终实现:"
  puts File.read(path).lines.grep(/a \+ b|a - b/)
  content = File.read(path)
  puts "== 闭环成立? #{content.include?('a + b') && !content.include?('a - b')}"
end