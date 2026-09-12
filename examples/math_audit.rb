# frozen_string_literal: true

# 学完小学数学 · 验收
# 目的：对 ra 已内化的四则运算（plugins/ra.rb 里 add/sub/mul/div）做一次可复现的追体验收。
# 用的武器是三件套（可编程验证器 + 隔离子进程 + 方法库）：
#   1. library —— 先自查方法库：ra 到底会什么
#   2. verify(cases + raises) —— 在隔离子进程里批量真算，含"除数为 0"边界
#   3. 全部通过才算 ra"学完小学数学"
#
# 纯离线，不需要 API key。运行：ruby -Ilib examples/math_audit.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
knowledge = RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME,
                                     File.expand_path('lessons.rb', __dir__)).load!
hub = RubyAgent::DocHub.new
hub.mount(ra)
hub.mount(knowledge)

agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([]),
                                 writable_plugins: ['ra'])

puts "== 1. ra 的方法库（library）"
puts agent.invoke_tool('library', { 'plugin' => 'ra' })

puts "\n== 2. 四则运算隔离验证（多算例 + 除 0 边界）"
checks = [
  ['add', [{ 'args' => [-1, 2], 'expected' => 1 }, { 'args' => [2, 3], 'expected' => 5 },
           { 'args' => [1.5, 2], 'expected' => 3.5 }]],
  ['sub', [{ 'args' => [-1, 2], 'expected' => -3 }, { 'args' => [5, 3], 'expected' => 2 }]],
  ['mul', [{ 'args' => [-1, 2], 'expected' => -2 }, { 'args' => [3, 0], 'expected' => 0 },
           { 'args' => [1.5, 2], 'expected' => 3.0 }]],
  ['div', [{ 'args' => [6, 2], 'expected' => 3.0 }, { 'args' => [5, 2], 'expected' => 2.5 },
           { 'args' => [1, 0], 'raises' => 'ArgumentError' }]]
]

passed = 0
checks.each do |method, cases|
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => method, 'cases' => cases })
  puts "  #{method}: #{result}"
  passed += 1 if result.start_with?('验证通过')
end

puts "\n== 3. 经验库（lessons）"
lesson = knowledge.registry.find { |_k, v| v['tags'].to_s.include?('四则运算') }
puts "  #{lesson&.last&.fetch('note', '')}"

puts "\n== 验收结论 =="
if passed == 4
  puts "✨ ra 学完小学数学：add/sub/mul/div 全数在隔离验证器下通过（含除 0 边界），经验已沉淀"
else
  puts "❌ 未全数通过（#{passed}/4），数学内化有缺口"
  exit 1
end