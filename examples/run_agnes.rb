# frozen_string_literal: true

# 用 Agnes（OpenAI 兼容）真实跑一次 Sprint 6 自修改闭环。
#
# 用法：
#   AGNES_API_KEY=sk-... ruby -Ilib examples/run_agnes.rb
#   AGNES_API_KEY=sk-... AGNES_BASE_URL=https://apihub.agnes-ai.com/v1 AGNES_MODEL=agnes-2.5-flash ruby -Ilib examples/run_agnes.rb
#
# 任务：让模型把 math 插件的 solve 改成一个错误实现，验证命中"自动回滚"，
# 再交给模型自己修正为正确实现并验证通过。

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

api_key = ENV['AGNES_API_KEY']
abort '缺少 AGNES_API_KEY（示例见脚本头部注释）' if api_key.nil? || api_key.empty?

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'

Dir.mktmpdir('agnes-demo') do |dir|
  path = File.join(dir, 'math.rb')
  File.write(path, <<~RUBY)
    # @doc role: 先加后减，求最终答案
    def solve(a, b)
      a + b
    end
  RUBY

  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('math', path))

  llm = RubyAgent::DeepSeekAdapter.new(
    api_key: api_key,
    base_url: base_url,
    model: model,
    timeout: 60,
    max_retries: 1
  )
  puts "== 模型: #{llm.inspect}"

  agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, max_steps: 12)
  agent.on(:llm_response) { |e| puts "\n── 模型回复 (#{e[:index]}):\n#{e[:content]}" }
  agent.on(:tool_call)    { |e| puts "→ 调用工具: #{e[:tool]} #{e[:input]}" }
  agent.on(:observation)  { |e| puts "  观察: #{e[:observation]}" }
  agent.on(:code_change)  { |e| puts "  ★ code_change: #{e[:method]} #{e[:status]}" }
  agent.on(:verify)       { |e| puts "  ★ verify: ok=#{e[:ok]} actual=#{e[:actual]} expected=#{e[:expected]}" }
  agent.on(:rollback)     { |e| puts "  ★ rollback: #{e[:method]}" }

  task = <<~TASK
    你的任务是修正 math 插件里的 solve 方法。
    当前实现是 a + b（减法也对不上？先看现状）。
    请严格按 ReAct 格式作答，先走一大步：
    1) 用 read_code 查看 solve 当前源码；
    2) 用 apply_code 把它改成“a - b”（即 def solve(a, b) 里返回 a - b）；
    3) 用 verify 跑 {plugin: math, method: solve, args: [1, 2], expected: 3}。
       注意：solve(1,2) 用 a - b 算出来是 -1，verify 会失败，
       并且系统会“自动回滚”你的修改 —— 你会从 Observation 里看到【已自动回滚】。
    4) 回滚后，用 apply_code 改成正确的“a + b”，再用 verify 用相同参数再验证一次；
    5) 最后用 Final Answer 总结：你的修改最终是否 verify 通过、盘中代码是否是正确的 a + b。
  TASK

  answer = agent.run(task)
  puts "\n== Final Answer: #{answer.inspect}"

  puts "\n== 审计轨迹:"
  agent.state.code_changes.each { |c| puts "  #{c[:plugin]}##{c[:method]} → #{c[:status]}" }

  puts "\n== 磁盘最终实现:"
  puts File.read(path).lines.grep(/a \+ b|a - b|a \* 10/)

  content = File.read(path)
  verified = (agent.state.code_changes.last&.[](:status) == :verified)
  correct = content.include?('a + b')
  puts "\n== 结果: status=#{agent.state.status} 自改已验证=#{verified} 磁盘正确=#{correct} 闭环成立=#{verified && correct}"
end