$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'ruby_agent/prop_solver'
require 'json'
require 'time'

# BBH·logical-deduction 接入实验——分层升降维在"求解任务"上的试金：
#   LLM 干"升维语义层"（把排序题的自然语言约束抽成标准谓词，不含推理），
#   Ruby+PropSolver 干"降维验证层"（谓词→位置命题 AST + 全序公理 + 真值枚举唯一蕴含）。
# 判分：机器在"每个候选占据 query_pos 位"的蕴含查询下给出唯一解 == 标准答案 → PASS。
# 附 gold 约束基线：同一题目用内置权威约束跑同一机器，隔离"题可机解"与"LLM 抽取保真"两个量。
#
# 用法：ruby -Ilib examples/bbh_logical.rb          （真机：LLM 语义层 + 机器验证）
#       ruby -Ilib examples/bbh_logical.rb --gold    （仅 gold 约束跑机器求解，不按键）
ROOT = File.expand_path('..', __dir__)

# 6 道 3-object 排序题（保证唯一解）。query_pos=问"谁在左起第几"; expected=标准答案。
PROBLEMS = [
  { name: 'left-chain', text: '排队题：物品 A 在物品 B 的左边，物品 B 在物品 C 的左边。问：谁在队列最右端？',
    query_pos: 3, expected: 'C', gold: [['left', 'A', 'B'], ['left', 'B', 'C']] },
  { name: 'between-middle', text: '排序题：物品 A 在物品 B 和物品 C 之间，且物品 A 在物品 B 的右边。问：谁排正中间？',
    query_pos: 2, expected: 'A', gold: [['between', 'A', 'B', 'C'], ['right', 'A', 'B']] },
  { name: 'adjacent-left-end', text: '排队题：物品 A 紧挨在物品 B 的左边（相邻），物品 C 在最右端。问：谁在最左端？',
    query_pos: 1, expected: 'A', gold: [['left', 'A', 'B'], ['adjacent', 'A', 'B'], ['pos', 'C', 3]] },
  { name: 'pos-and-exclusion', text: '排序题：有三个物品 A、B、C，物品 A 在第 2 位，物品 B 不在最右端。问：谁在最左端？',
    query_pos: 1, expected: 'B', gold: [['pos', 'A', 2], ['not_pos', 'B', 3]] },
  { name: 'right-between-question', text: '排序题：物品 A 在物品 B 的右边，物品 C 在物品 A 和物品 B 之间。问：谁排在从左数第 2 位？',
    query_pos: 2, expected: 'C', gold: [['right', 'A', 'B'], ['between', 'C', 'A', 'B']] },
  { name: 'ends-and-middle', text: '排队题：物品 A 在最左端，物品 B 在物品 A 的右边，物品 C 在最右端。问：谁正中间？',
    query_pos: 2, expected: 'B', gold: [['pos', 'A', 1], ['right', 'B', 'A'], ['pos', 'C', 3]] }
].freeze

BBH_PROMPT = <<~PROMPT.freeze
  你是降维管线的"升维语义层"。把下面这道排序题的约束抽成标准谓词（只抽结构，不推理、不解答案）：
  物品名用大写字母（写全该题出现的全部物品；最多 3 个）；位置从左到右编号 1,2,3…；
  谓词白名单：
    ["pos","X",k]          X 就在第 k 位
    ["not_pos","X",k]      X 不在第 k 位（"X 不在最右端"→["not_pos","X",3]）
    ["left","X","Y"]       X 严格在 Y 左边（左右任意距离）
    ["right","X","Y"]      X 严格在 Y 右边
    ["end","X"]            X 在最左端或最右端
    ["adjacent","X","Y"]   X 与 Y 相邻（位置差恰为 1）
    ["between","X","Y","Z"] X 夹在 Y 与 Z 之间（位置在二者正中间）
  规则：只输出句子直接给出的约束，不加任何常识或未明说的物品关系；问句本身不是约束、不能写成谓词。
  述位化映射（保真优先，宁可写精确不可写宽）：「在最左端」→["pos","X",1]，「在最右端」→["pos","X",n]，「在第 k 位」→["pos","X",k]，
  「不在最右/左端」→["not_pos","X",n/1]；只有字面就是"两端之一"（如"在其中一端"）才用["end","X"]。
  输出纯 JSON：{"objects":["A","B","C"],"constraints":[["left","A","B"],…]}
  ⚠ 用 Action=Final Answer 提交，Action Input 填 JSON。
  论断：「{{TEXT}}」
PROMPT

def extract_json(text)
  l = text.rindex('{')
  r = text.rindex('}')
  return nil unless l && r && r > l

  JSON.parse(text[l..r])
rescue JSON::ParserError
  nil
end

def build_agent
  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('ra', File.expand_path('plugins/ra.rb', ROOT)).load!)
  llm = RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
  RubyAgent::AgentLoop.new(hub: hub, llm: llm, max_steps: 8, writable_plugins: ['ra'], mode: :exam)
end

def run_semantic(prompt)
  3.times do |attempt|
    answer = begin
      build_agent.run(prompt).to_s
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 60]}"
    end
    answer = answer.sub(/Final Answer:?\s*/i, '').strip
    next if answer.empty?

    data = extract_json(answer)
    return data if data.is_a?(Hash) && data['objects'].is_a?(Array) && data['constraints'].is_a?(Array) &&
                   data['objects'].size.between?(2, 3)

    warn "    ⚠ 第#{attempt + 1}次语义层 JSON 不合法，重试…" if attempt < 2
  end
  nil
end

# —— 降维：谓词 → 位置命题 AST（n=3）——
def atom(x, p)
  "#{x}#{p}" # 原子"A1"=A 在第 1 位
end

def disj_of(exprs)
  return exprs.first if exprs.size == 1

  exprs.reduce { |acc, e| ['or', acc, e] }
end

def expand(c, n)
  case c[0]
  when 'pos'
    atom(c[1], c[2].to_i)
  when 'not_pos'
    ['not', atom(c[1], c[2].to_i)]
  when 'left'
    disj_of((1..n).to_a.flat_map { |i| ((i + 1)..n).map { |j| ['and', atom(c[1], i), atom(c[2], j)] } })
  when 'right'
    expand(['left', c[2], c[1]], n)
  when 'adjacent'
    disj_of((1..n).to_a.flat_map do |i|
      ((i + 1)..n).select { |j| (j - i) == 1 }.map { |j| ['and', atom(c[1], i), atom(c[2], j)] }
    end)
  when 'end'
    ['or', atom(c[1], 1), atom(c[1], n)]
  when 'between'
    x, y, z = c[1], c[2], c[3]
    triples = (1..n).to_a.product((1..n).to_a, (1..n).to_a)
    disj_of(triples.select { |i, j, k| (i < j && j < k) || (k < j && j < i) }
      .map { |i, j, k| ['and', atom(y, i), atom(x, j), atom(z, k)] })
  else
    raise "未知谓词 #{c[0].inspect}"
  end
end

# —— 全序公理：每物恰一位 + 每位恰一物（命题层把物品×位置平面钉住）——
def axioms(names)
  n = 3
  out = []
  names.each do |x|
    out << disj_of((1..n).map { |p| atom(x, p) })
    (1..n).to_a.combination(2).each { |a, b| out << ['not', ['and', atom(x, a), atom(x, b)]] }
  end
  (1..n).each do |p|
    out << disj_of(names.map { |x| atom(x, p) })
    names.combination(2).each { |a, b| out << ['not', ['and', atom(a, p), atom(b, p)]] }
  end
  out
end

def solve(premises, names, query_pos)
  names.select { |x| PropSolver.verify(premises, atom(x, query_pos))[:entailed] }
end

puts '════════ BBH·logical-deduction（3-objects）— 降维验证层接入 ════════'
rows = []
PROBLEMS.each do |t|
  gold_data = { 'objects' => %w[A B C], 'constraints' => t[:gold], 'query_pos' => t[:query_pos] }
  gold_premises = axioms(%w[A B C]) + t[:gold].map { |c| expand(c, 3) }
  gold_sol = solve(gold_premises, %w[A B C], t[:query_pos])

  skip_llm = ARGV.include?('--gold')
  llm_data = skip_llm ? gold_data : run_semantic(BBH_PROMPT.gsub('{{TEXT}}', t[:text]))

  if llm_data.nil?
    rows << { name: t[:name], verdict: 'FAIL', diag: 'VOID：语义层 JSON 不合法（输出协议违约）' }
    puts "  FAIL  #{t[:name]}  [gold 机器解=#{gold_sol.inspect}]  VOID：语义层 3 试全败（协议违约）"
    next
  end

names = llm_data['objects'].map(&:to_s)
  begin
    premises = axioms(names) + llm_data['constraints'].map { |c| expand(c, 3) }
    unless PropSolver.consistent?(premises)
      rows << { name: t[:name], verdict: 'FAIL', diag: '降维前提矛盾（真空蕴含）——语义层漏报对象/约束互斥', objects: names,
                constraints: llm_data['constraints'], gold_sol: t }.compact
      puts "  FAIL  #{t[:name]}  [gold=#{t[:expected]}]  前提矛盾：语义层漏报对象或约束互斥 → 机器真空蕴含不可信"
      next
    end
    sol = solve(premises, names, t[:query_pos])
  rescue StandardError => e
    rows << { name: t[:name], verdict: 'FAIL', diag: "降维 crash: #{e.message[0, 60]}" }
    puts "  FAIL  #{t[:name]}  [gold=#{gold_sol.inspect}]  降维 crash：#{e.message[0, 70]}"
    next
  end

  llm_set = llm_data['constraints'].map(&:join)
  gold_set = t[:gold].map(&:join)
  answer = sol.size == 1 ? sol.first : (sol.empty? ? '∅无解' : "多解#{sol.inspect}")
  pass = answer == t[:expected]
  verdict = pass ? 'PASS' : 'FAIL'
  rows << { name: t[:name], verdict: verdict, gold_sol: gold_sol, llm_sol: answer, objects: names,
            constraints: llm_data['constraints'],
            overlap: (llm_set & gold_set).size.to_f / gold_set.size }
  puts "  #{verdict}  #{t[:name]}  [gold=#{gold_sol.inspect} 机器解=#{answer}]"
  puts "    └ 语义层 objects #{names.inspect}, 约束=#{llm_data['constraints'].inspect}（gold 交集 #{format('%.0f%%', rows.last[:overlap] * 100)}）"
end

passed = rows.count { |r| r[:verdict] == 'PASS' }
puts
puts '════════ 结果 ════════'
puts "  #{passed}/#{rows.size} PASS（LLM 语义层保真 → 降维验证）"
puts "  gold 约束机器求解：#{(rows.count { |r| r[:gold_sol].size == 1 })}/#{rows.size} 题唯一可解（隔离『题本身可机解』）"

unless ARGV.include?('--gold')
  Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
  artifact = File.join(ROOT, 'examples', 'gradebook', "bbh_logical_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(artifact, JSON.pretty_generate(
    generated_at: Time.now.iso8601, model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
    total: rows.size, passed: passed, rows: rows
  ))
  puts "  证据存档: #{artifact}"
end