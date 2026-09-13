$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# 逻辑学·进阶错题回炉：上次 4 题未过，这次针对病因逐题辅导重做。
# 判分仍是隔离 verify（全真值表）——教得再漂亮，真值表说了算。

RETRAIN = [
  ['modus_ponens', '肯定前件（真值函数版）：输出必须恒等于参数 q 的布尔值',
   [[[true, true], true], [[true, false], false], [[false, true], true], [[false, false], false]],
   '上次你的实现返回了别的值。真题语义：把 (p→q)∧p 当布尔函数求值，其输出对任意 p,q 都恰好等于 q。请直接返回这个布尔值；禁止抛异常、禁止前提守卫。'],
  ['modus_tollens', '否定后件（真值函数版）：输出必须恒等于 ¬p 的布尔值',
   [[[true, true], false], [[true, false], false], [[false, true], true], [[false, false], true]],
   '上次你把前提 (p→q)∧¬q 当守卫，前提不成立就抛 ArgumentError，导致判分失败。真题要求把它当纯布尔函数：输出恒等于 ¬p，对全部 4 组真假指派都返回值，不抛异常。'],
  ['de_morgan_nor', '德摩根Ⅰ：¬(p∨q) ≡ ¬p∧¬q。nor(a,b) 的定义就是 ¬(a∨b)，因此 ¬(p∨q) 直接就是 nor(p,q)；验证两式等价应返回布尔，恒成立则恒为 true',
   [[[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
   '上次你的 right = nor(nor(p,p), nor(q,q)) 是错的：nor(nor(p,p),nor(q,q)) = ¬(¬p∨¬q) = p∧q，那是双重否定化成了 AND，不是 ¬p∧¬q。记住 ¬(p∨q) ≡ ¬p∧¬q，且 nor 本身就是 ¬(a∨b)。'],
  ['law_of_equivalence', '等值定义验证：判断 biconditional(p,q) 与 (implication(p,q) && implication(q,p)) 是否对所有真假指派恒等，返回布尔，恒等则恒为 true',
   [[[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
   '上次你实现成返回 biconditional(p,q) 的真值（即 p↔q 本身），但题目要你【验证两式恒等】。请返回 biconditional(p,q) == (implication(p,q) && implication(q,p))，这样才会有问题所需的恒 true 结果。']
].freeze

ROOT = File.expand_path('..', __dir__)
ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
knowledge = RubyAgent::Knowledge.new(File.expand_path('../examples/lessons.rb', __dir__))
hub = RubyAgent::DocHub.new
hub.mount(ra)
hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)
llm = RubyAgent::DeepSeekAdapter.new(
  base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
  api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge, max_steps: 25, writable_plugins: ['ra'])
agent.on(:tool_call) { |e| puts "    → #{e[:tool]}" }

def coach_one(agent, qi, name, sem, coach)
  agent.run(<<~TASK)
    逻辑学补考·第 #{qi} 题：在 plugins/ra 里实现方法 #{name} —— #{sem}。
    老师讲评（请重视，这是你上次挂科的病因）：#{coach}
    步骤：1) apply_code 写实现；2) teach 补 @doc 契约（role 一句话、note 简短）；3) verify 自证，把全部 #{qi <= 1 ? 4 : 4} 组真假指派跑一遍。
    Final Answer 报告 #{name} 的实现与自证结果。
  TASK
rescue StandardError => e
  puts "     run 异常：#{e.class}: #{e.message[0, 90]}"
end

def judge(agent, name, cases)
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => name, 'cases' => cases })
  passed = result.start_with?('验证通过')
  puts "     [判分#{passed ? '√' : '✗'}] #{name}: #{result[0, 100]}"
  passed
end

puts '【回炉】逻辑学进阶·错题 re-teach（每道至多 3 轮，病因已讲评）'
final_cases = {}
RETRAIN.each_with_index do |(name, sem, table, coach), qi|
  cases = table.map { |(args, expected)| { 'args' => args, 'expected' => expected } }
  final_cases[name] = cases
  puts "  #{qi + 1}.#{name} — #{sem.slice(0, 44)}"
  done = false
  3.times do |attempt|
    puts "   · 第#{attempt + 1}轮作答…"
    coach_one(agent, qi + 1, name, sem, coach)
    break if (done = judge(agent, name, cases))
  end
  puts done ? "     ✓ #{name} 回炉成功" : "     ✗ #{name} 仍未过（留待下次）"
end

puts
score = 0
total = 0
final_cases.each do |name, cases|
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => name, 'cases' => cases })
  passed = result.start_with?('验证通过')
  total += cases.size
  score += cases.size if passed
  puts "  回炉复核 #{passed ? '√' : '✗'} #{name}"
end
puts
puts "【回炉成绩】错题补考 #{score}/#{total}"
puts score == total ? '评级：4 题全部回炉成功，判分器作证' : "评级：剩 #{RETRAIN.size - final_cases.keys.count { |n| judge(agent, n, final_cases[n]) }} 题未过"