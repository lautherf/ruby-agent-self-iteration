$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'json'
require 'time'

# BBH·logical-deduction 接入实验（A1：机层升档）——分层升降维在"求解任务"上的试金：
#   LLM 干"升维语义层"（把排序题的自然语言约束抽成标准谓词，不含推理），
#   机器干"降维验证层"：排序任务的真值模型=全序排列 → 直接枚举 n! 条排列、
#   逐条验约束，取 query_pos 位上"满足全部约束的排列"唯一一致的对象为答案。
#   （取代早期位置命题位向量穷举：2^(n²) 位向量 explode，n! 排列 7!=5040 瞬间。）
# 判分：机器唯一解 == 标准答案 → PASS；空排列集=前提不可满足（真空哑果）特殊隔出。
# 附 gold 约束基线：同题用内置权威约束跑同一机器，隔离"题可机解"与"LLM 抽取保真"。
#
# 用法：ruby -Ilib examples/bbh_logical.rb          （真机：LLM 语义层 + 机器验证）
#       ruby -Ilib examples/bbh_logical.rb --gold    （仅 gold 约束跑机器求解，不按键）
ROOT = File.expand_path('..', __dir__)

# 题卷：6 道 3-object + 3 道 7-object。构造法=先定目标全序、反推本卷所需约束、
# gold 基线跑通唯一解才留题。query_pos=问"谁在左起第几"; expected=标准答案。
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
    query_pos: 2, expected: 'B', gold: [['pos', 'A', 1], ['right', 'B', 'A'], ['pos', 'C', 3]] },
  { name: 'seven-chain-pins', text: '有七个物品 A、B、C、D、E、F、G。物品 A 在第 3 位，物品 G 在最左端，物品 B 在最右端，物品 D 在物品 E 的左边，物品 D 与物品 E 相邻，物品 C 在物品 D 的左边，物品 F 在物品 D 的左边，物品 C 在物品 F 的右边。问：谁在队列第 5 位？',
    query_pos: 5, expected: 'D', gold: [['pos', 'A', 3], ['pos', 'G', 1], ['pos', 'B', 7], ['left', 'D', 'E'], ['adjacent', 'D', 'E'], ['left', 'C', 'D'], ['left', 'F', 'D'], ['right', 'C', 'F']] },
  { name: 'seven-between-pins', text: '有七个物品 A、B、C、D、E、F、G。物品 G 在第 2 位，物品 A 在第 4 位，物品 D 在最右端，物品 B 在第 6 位，物品 E 在物品 A 的左边，物品 F 在物品 E 和物品 C 之间，物品 C 在物品 F 的右边。问：谁在队列第 6 位？',
    query_pos: 6, expected: 'B', gold: [['pos', 'G', 2], ['pos', 'A', 4], ['pos', 'D', 7], ['pos', 'B', 6], ['left', 'E', 'A'], ['between', 'F', 'E', 'C'], ['right', 'C', 'F']] },
  { name: 'seven-adjacent-pins', text: '有七个物品 A、B、C、D、E、F、G。物品 B 在第 3 位，物品 A 在第 5 位，物品 C 在最右端，物品 E 与物品 C 相邻，物品 G 在物品 B 的右边，物品 F 在物品 D 的左边。问：谁在队列最左端？',
    query_pos: 1, expected: 'F', gold: [['pos', 'B', 3], ['pos', 'A', 5], ['pos', 'C', 7], ['adjacent', 'E', 'C'], ['right', 'G', 'B'], ['left', 'F', 'D']] }
].freeze

BBH_PROMPT = <<~PROMPT.freeze
  你是降维管线的"升维语义层"。把下面这道排序题的约束抽成标准谓词（只抽结构，不推理、不解答案）：
  物品名用大写字母（写全该题出现的全部物品；最多 7 个）；位置从左到右编号 1,2,3…；
  谓词白名单：
    ["pos","X",k]          X 就在第 k 位
    ["not_pos","X",k]      X 不在第 k 位（"X 不在最右端"→["not_pos","X",n]）
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
                   data['objects'].size.between?(2, 7)

    warn "    ⚠ 第#{attempt + 1}次语义层 JSON 不合法，重试…" if attempt < 2
  end
  nil
end

# —— A2 随机化题目生成（property-based）：随机目标全序 → 随机约束序列 →
#    机器验"全序唯一解"才收题，去除手写挑题偏差、杜绝与官方数据重叠 ——
def rand2_indices(rng, n)
  i = rng.rand(n)
  j = rng.rand(n)
  j = rng.rand(n) while j == i
  [i, j].sort
end

def random_constraint(rng, order)
  n = order.size
  case rng.rand(4)
  when 0
    x = order[rng.rand(n)]
    if rng.rand(2).zero?
      ['pos', x, idx(order, x)]
    else
      ['not_pos', x, ((1..n).to_a - [idx(order, x)]).sample(random: rng)]
    end
  when 1
    i, j = rand2_indices(rng, n)
    rng.rand(2).zero? ? ['left', order[i], order[j]] : ['right', order[j], order[i]]
  when 2
    i = rng.rand(n - 1)
    [['adjacent', order[i], order[i + 1]], ['adjacent', order[i + 1], order[i]]].sample(random: rng)
  else
    triple = order.sample(3, random: rng).sort_by { |x| idx(order, x) }
    ['between', triple[1], triple[0], triple[2]]
  end
end

def sentence_for(c, n)
  case c[0]
  when 'pos'       then "物品 #{c[1]} 在第 #{c[2]} 位"
  when 'not_pos'   then "物品 #{c[1]} 不在#{c[2] == 1 ? '最左端' : c[2] == n ? '最右端' : "第 #{c[2]} 位"}"
  when 'left'      then "物品 #{c[1]} 在物品 #{c[2]} 的左边"
  when 'right'     then "物品 #{c[1]} 在物品 #{c[2]} 的右边"
  when 'adjacent'  then "物品 #{c[1]} 与物品 #{c[2]} 相邻"
  when 'between'   then "物品 #{c[1]} 在物品 #{c[2]} 和物品 #{c[3]} 之间"
  end
end

def gen_problem(rng, n)
  names = Array.new(n) { |i| ('A'.ord + i).chr }
  40.times do
    order = names.shuffle(random: rng)
    cons = []
    12.times do
      c = random_constraint(rng, order)
      cons << c
      cons.pop if satisfying_orders(names, cons).empty?
      unique = satisfying_orders(names, cons)
      next unless unique.size == 1

      q = rng.rand(1..n)
      puts "DBG order=#{order.join} unique=#{unique.map(&:join).inspect} q#{q} exp=#{unique.first[q - 1]}" if ENV['DBG']
      return { name: "fuzz#{format('%02d', rng.rand(100))}", names: names, constraints: cons, query_pos: q,
               expected: unique.first[q - 1],
               text: "#{n == 3 ? '有三个物品' : '有七个物品'} #{names.join('、')}。#{cons.map { |c| sentence_for(c, n) }.join('，')}。问：谁在队列第 #{q} 位？" }
    end
  end
  nil
end

def run_fuzz(count, live:)
  rng = Random.new((ENV['SEED'] || 42).to_i)
  problems = []
  tries = 0
  while problems.size < count && tries < 300
    p = gen_problem(rng, [3, 7].sample(random: rng))
    tries += 1
    next unless p

    problems << p
    puts "  ✓ #{p[:name]}：n=#{p[:names].size} 约束#{"%d" % p[:constraints].size} 问第 #{p[:query_pos]} 位 → #{p[:expected]}（gold 唯一）"
  end
  puts "  生成质量：#{problems.size}/#{count} 题唯一可解（尝试 #{tries} 次；gold 校验通过才收题）"
  return if problems.empty?

  rows = []
  problems.each do |p|
    llm_data = live ? run_semantic(BBH_PROMPT.gsub('{{TEXT}}', p[:text])) : nil
    if live && llm_data.nil?
      rows << { name: p[:name], verdict: 'FAIL', diag: 'VOID：语义层 JSON 不合法' }
      puts "  FAIL  #{p[:name]}  [gold=#{p[:expected]}]  VOID"
      next
    end
    if live
      names = llm_data['objects'].map(&:to_s)
      orders = satisfying_orders(names, llm_data['constraints'])
      if orders.empty?
        rows << { name: p[:name], verdict: 'FAIL', diag: '空排列集（漏报对象/约束互斥）', objects: names, constraints: llm_data['constraints'] }
        puts "  FAIL  #{p[:name]}  [gold=#{p[:expected]}]  ∅无排列 → 真空哑果"
        next
      end
      answers = orders.map { |o| o[p[:query_pos] - 1] }.uniq
      answer = answers.size == 1 ? answers.first : "多解#{answers.inspect}"
      rows << { name: p[:name], verdict: answer == p[:expected] ? 'PASS' : 'FAIL', machine: answer, objects: names, constraints: llm_data['constraints'], models: orders.size }
      puts "  #{answer == p[:expected] ? 'PASS' : 'FAIL'}  #{p[:name]}  [gold=#{p[:expected]} 机器解=#{answer}（#{orders.size} 排列）]"
      puts "    └ 约束=#{llm_data['constraints'].inspect}"
    else
      rows << { name: p[:name], verdict: 'PASS', gold: p[:constraints], expected: p[:expected], query_pos: p[:query_pos], text: p[:text] }
    end
  end

  passed = rows.count { |r| r[:verdict] == 'PASS' }
  puts "  fuzz 真机：#{passed}/#{rows.size} PASS（LLM 语义层→降维验证）" if live
  Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
  artifact = File.join(ROOT, 'examples', 'gradebook', "bbh_fuzz_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(artifact, JSON.pretty_generate(generated_at: Time.now.iso8601, live: live,
    model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash', total: rows.size, passed: passed, rows: rows))
  puts "  证据存档: #{artifact}"
end

# —— 降维机层：全序排列枚举（排序任务的真值模型=n! 条排列）——
def idx(order, x)
  order.index(x) + 1
end

def satisfies?(order, c)
  case c[0]
  when 'pos'      then idx(order, c[1]) == c[2].to_i
  when 'not_pos'  then idx(order, c[1]) != c[2].to_i
  when 'left'     then idx(order, c[1]) < idx(order, c[2])
  when 'right'    then idx(order, c[1]) > idx(order, c[2])
  when 'end'      then [1, order.size].include?(idx(order, c[1]))
  when 'adjacent' then (idx(order, c[1]) - idx(order, c[2])).abs == 1
  when 'between'
    y, x, z = c[2], c[1], c[3] # x 夹在 y,z 之间
    (idx(order, y) < idx(order, x) && idx(order, x) < idx(order, z)) ||
      (idx(order, z) < idx(order, x) && idx(order, x) < idx(order, y))
  else
    raise "未知谓词 #{c[0].inspect}"
  end
end

# 返回满足全部约束的全序排列集；约束对象超出 names = 语义层对象集与约束不一致
def satisfying_orders(names, constraints)
  constraints.each do |c|
    c.drop(1).each do |arg|
      raise "约束引用了未申报对象 #{arg}" if arg.is_a?(String) && !names.include?(arg)
    end
  end
  orders = names.permutation(names.size).select { |o| constraints.all? { |c| satisfies?(o, c) } }
  orders
end

def answer_at(orders, query_pos)
  candidates = orders.map { |o| o[query_pos - 1] }.uniq
  if orders.empty?
    nil # 不可满足 → 真空哑果
  elsif candidates.size == 1
    candidates.first
  else
    "多解#{candidates.inspect}"
  end
end

if (fuzz_at = ARGV.index('--fuzz'))
  run_fuzz(ARGV[fuzz_at + 1].to_i, live: ARGV.include?('--live'))
  exit
end

if ARGV.include?('--verify-archive')
  rows = JSON.parse(File.read(ARGV[ARGV.index('--verify-archive') + 1]))['rows']
  rows.each do |r|
    next unless r['gold'] && r['text']

    n = r['text'].include?('七个') ? 7 : 3
    names = Array.new(n) { |i| ('A'.ord + i).chr }
    orders = satisfying_orders(names, r['gold'])
    ans = orders.map { |o| o[r['query_pos'] - 1] }.uniq
    ok = orders.empty? ? (r['expected'] == '无解') : (ans.size == 1 && ans.first == r['expected'])
    puts "  #{ok ? 'OK ' : '✗✗'} #{r['name']}: solver=#{ans.inspect} expected=#{r['expected']}"
  end
  exit
end

puts '════════ BBH·logical-deduction — 降维验证层（全序排列枚举）════════'
rows = []
PROBLEMS.each do |t|
  names_all = t[:name].start_with?('seven') ? %w[A B C D E F G] : %w[A B C]
  gold_orders = satisfying_orders(names_all, t[:gold])
  gold_ans = gold_orders.empty? ? '∅无解' : answer_at(gold_orders, t[:query_pos])

  skip_llm = ARGV.include?('--gold')
  llm_data = skip_llm ? { 'objects' => names_all, 'constraints' => t[:gold] } : run_semantic(BBH_PROMPT.gsub('{{TEXT}}', t[:text]))

  if llm_data.nil?
    rows << { name: t[:name], verdict: 'FAIL', diag: 'VOID：语义层 JSON 不合法（输出协议违约）' }
    puts "  FAIL  #{t[:name]}  [gold=#{gold_ans}]  VOID：语义层 3 试全败（协议违约）"
    next
  end

  names = llm_data['objects'].map(&:to_s)
  begin
    orders = satisfying_orders(names, llm_data['constraints'])
  rescue StandardError => e
    rows << { name: t[:name], verdict: 'FAIL', diag: "降维 crash: #{e.message[0, 60]}" }
    puts "  FAIL  #{t[:name]}  [gold=#{gold_ans}]  降维 crash：#{e.message[0, 70]}"
    next
  end

  if orders.empty?
    rows << { name: t[:name], verdict: 'FAIL', diag: '空排列集（前提不可满足，机器真空哑果）——漏报对象或约束互斥', objects: names,
              constraints: llm_data['constraints'] }
    puts "  FAIL  #{t[:name]}  [gold=#{gold_ans}]  前提矛盾：无任何全序满足约束 → 机器真空哑果不可信"
    next
  end

  answer = answer_at(orders, t[:query_pos])
  pass = answer == t[:expected]
  verdict = pass ? 'PASS' : 'FAIL'
  rows << { name: t[:name], verdict: verdict, gold_ans: gold_ans, machine: answer, objects: names,
            constraints: llm_data['constraints'],
            models: orders.size }
  puts "  #{verdict}  #{t[:name]}  [gold=#{gold_ans} 机器解=#{answer}（#{orders.size} 排列）]"
  puts "    └ 语义层 objects #{names.inspect}, 约束=#{llm_data['constraints'].inspect}"
end

passed = rows.count { |r| r[:verdict] == 'PASS' }
puts
puts '════════ 结果 ════════'
puts "  #{passed}/#{rows.size} PASS（LLM 语义层保真 → 降维验证）"
puts "  gold 约束机器求解：#{(rows.count { |r| r[:gold_ans].to_s != '∅无解' && !r[:gold_ans].to_s.start_with?('多解') })}/#{rows.size} 题唯一可解（隔离『题本身可机解』）"

unless ARGV.include?('--gold')
  Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
  artifact = File.join(ROOT, 'examples', 'gradebook', "bbh_logical_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(artifact, JSON.pretty_generate(
    generated_at: Time.now.iso8601, model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
    total: rows.size, passed: passed, rows: rows
))
  puts "  证据存档: #{artifact}"
end