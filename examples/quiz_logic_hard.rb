$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# 逻辑学·进阶卷（考真本事）：不再背单算子真值表，
# 而是把逻辑法则交给 ra 自己组合实现 —— 会不会逻辑一眼见分晓。
#
# 每道题给出【逻辑学语义】，ra 需 apply_code 实现复合逻辑方法、
# teach @doc 契约、verify 自证；判分器用隔离 verify 按全真值表复核。

PAPER = [
  ['modus_ponens', '肯定前件（m.p. 规则）：(p→q) ∧ p，应推出结论 q',
   [[true, true], true], [[true, false], false], [[false, true], true], [[false, false], false]],
  ['modus_tollens', '否定后件（m.t. 规则）：(p→q) ∧ ¬q，应推出结论 ¬p',
   [[true, true], false], [[true, false], false], [[false, true], true], [[false, false], true]],
  ['law_of_contrapositive', '逆否等价律：p→q 当且仅当 ¬q→¬p（判断是否恒成立）',
   [[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
  ['de_morgan_nor', '德摩根Ⅰ：¬(p∨q) 与 ¬p∧¬q 等价（用 nor 表达并判断恒成立）',
   [[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
  ['de_morgan_nand', '德摩根Ⅱ：¬(p∧q) 与 ¬p∨¬q 等价（用 nand 表达并判断恒成立）',
   [[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
  ['absorption_law', '吸收律：p∧(p∨q) 与 p 等价（判断是否恒成立）',
   [[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]],
  ['excluded_middle', '排中律：p∨¬p 恒为真',
   [[true], true], [[false], true]],
  ['law_of_equivalence', '等值定义：p↔q 当且仅当 (p→q)∧(q→p)（判断是否恒成立）',
   [[true, true], true], [[true, false], true], [[false, true], true], [[false, false], true]]
].freeze

TASK = ''

# —— 构建 agent（真实模型）——
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

def judge_single(agent, name, cases)
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => name, 'cases' => cases })
  passed = result.start_with?('验证通过')
  puts "     [判分#{passed ? '√' : '✗'}] #{name}: #{result[0, 100]}"
  passed
end

def ask_one(agent, qi, name, sem)
  agent.run(<<~TASK)
    逻辑学进阶·第 #{qi} 题：在 plugins/ra 里实现方法 #{name} —— #{sem}。
    步骤：1) apply_code 写实现；2) teach 补 @doc 契约（role 一句话、note 简短）；3) verify 自证（真值表覆盖 p/q 全部组合）。
    Final Answer 报告 #{name} 的逻辑意义一句话。
  TASK
rescue StandardError => e
  puts "     run 异常：#{e.class}: #{e.message[0, 90]}"
end

puts "【发卷】逻辑学·进阶卷 —— #{PAPER.size} 道复合逻辑题（每题须自己实现 + teach + verify 自证）"
PAPER.each_with_index { |(name, sem, *expects), qi| puts "  #{qi + 1}. #{name}: #{sem.slice(0, 40)}…" }
puts
puts "【开考】ra 逐题作答（真实模型多步对话，每题至多 2 轮）…"

final_cases = {}
PAPER.each_with_index do |(name, sem, *expects), qi|
  cases = expects.map { |(args, expected)| { 'args' => args, 'expected' => expected } }
  final_cases[name] = cases
  puts "  #{qi + 1}.#{name} — #{sem.slice(0, 48)}"
  2.times do |attempt|
    puts "   · 第#{attempt + 1}轮作答…"
    ask_one(agent, qi + 1, name, sem)
    break if judge_single(agent, name, cases)
  end
end

puts
score = 0
total = 0
final_cases.each do |name, cases|
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => name, 'cases' => cases })
  passed = result.start_with?('验证通过')
  n = cases.size
  total += n
  score += n if passed
  puts "  复核 #{passed ? '√' : '✗'} #{name}（#{n} 格）"
end
puts
puts "【终考】逻辑学·进阶  #{score}/#{total}"
if score == total
  puts '评级：真学会 —— 复合逻辑函数全部与全真值表一致，会组合、懂推理规则'
elsif score.to_f / total >= 0.75
  puts '评级：会大半 —— 少数恒等式需补'
else
  puts "评级：需回炉（只答 #{score}/#{total}）"
end