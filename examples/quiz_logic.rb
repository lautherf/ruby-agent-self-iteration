$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# 逻辑学期终考：隔离判分，无需 LLM（verify 走子进程真实执行 ra 的方法）
PAPER = {
  'Q1 蕴含 p→q：p 真 q 假才为假' => ['implication',
    [true, true] => true, [true, false] => false, [false, true] => true, [false, false] => true],
  'Q2 双条件 p↔q：同真同假才为真' => ['biconditional',
    [true, true] => true, [true, false] => false, [false, true] => false, [false, false] => true],
  'Q3 异或 XOR：不同为真' => ['xor',
    [true, true] => false, [true, false] => true, [false, false] => false],
  'Q4 与非 NAND：同真才为假' => ['nand',
    [true, true] => false, [true, false] => true, [false, false] => true],
  'Q5 或非 NOR：同假才为真' => ['nor',
    [true, true] => false, [true, false] => false, [false, false] => true]
}.freeze

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
hub = RubyAgent::DocHub.new
hub.mount(ra)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([]), writable_plugins: ['ra'])

score = 0
total = 0
PAPER.each_with_index do |(question, (method, expectations)), qi|
  cases = expectations.map { |args, expected| { 'args' => args, 'expected' => expected } }
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => method, 'cases' => cases })
  passed = result.start_with?('验证通过')
  total += expectations.size
  score += expectations.size if passed
  mark = passed ? '√'.encode('UTF-8') : '✗'.encode('UTF-8')
  puts "  #{mark} #{question}  → #{result[0, 40]}…"
end

puts
puts "【终考】逻辑学 #{score}/#{total}"
puts score == total ? '评级：优秀（全部真值表准确）' : "评级：待补（错题见上）"