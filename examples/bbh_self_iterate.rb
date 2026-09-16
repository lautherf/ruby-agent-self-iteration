# frozen_string_literal: true

# RA 自迭代 BBH：框架自己跑失败闭环（IterationLoop 编排，非 shell-out）。
#
# 分工：
#   语义层 = AgentLoop(exam) 抽约束 → 机层 solve（bbh 插件，纯 Ruby）→ 判 FAIL
#   修复层 = 每个 FAIL 例交给一个"修复 Agent"（reuse 同一 hub/bbh 插件）：
#            read_code 看机层源码 → 先 verify 锁锚（该例已知正确事实）→
#            apply_code 改机层 → verify 确认 → learn 沉淀教训。
#   IterationLoop 逐轮跑：每轮结束自动把 Agent 自学的经验沉淀进 Knowledge，
#   下一轮 system prompt 经 DocHub for_llm 自动带上上一轮教训（闭环 #5 #6）。
#
# 用法：
#   AGNES_API_KEY=sk-... ruby -Ilib examples/bbh_self_iterate.rb \
#     /tmp/opencode/bbh/logical_deduction_five_objects.json \
#     --gradebook examples/gradebook/bbh_five_merged_20260916.json [--max-fail N] [--offline]

require 'json'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ROOT = File.expand_path('..', __dir__)
BBH_PLUGIN = File.join(ROOT, 'plugins', 'bbh.rb')
LESSONS = File.join(ROOT, 'examples', 'lessons.rb')
GRADEBOCK = File.join(ROOT, 'examples', 'gradebook')

def load_machine_layer
  mod = Module.new
  mod.module_eval(File.read(BBH_PLUGIN), BBH_PLUGIN, 1)
  Object.new.extend(mod)
end

def llm_adapter
  RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'],
    model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
end

SEM_PROMPT = <<~PROMPT.freeze
  你是降维管线的"升维语义层"。输入一道排序题（对象名已由机器解析，引用必须一字不差）。
  对象清单：{{OBJECTS}}
  任务：只把题干里的比较/位置关系句抽成标准谓词：
    ["before","X","Y"]  ["after","X","Y"]  ["adjacent","X","Y"]
    ["between","X","Y","Z"]  ["rank","X",k,"left"]（物理方位）  ["rank","X",k,"old/new/expensive/cheap/first"]（概念）
  声明 head ∈ {left,right,new,old,expensive,cheap,first}：本排序"最前/最新/最贵/第一名"端对应哪个概念。
  输出纯 JSON：{"objects":[...],"constraints":[...],"head":"..."}
  ⚠ 用 Action=Final Answer 提交，Action Input 填 JSON。
  题干：
  {{TEXT}}
PROMPT

def semantic_layer(objects, input)
  agent = RubyAgent::AgentLoop.new(
    hub: RubyAgent::DocHub.new,
    llm: llm_adapter,
    max_steps: 6,
    mode: :exam
  )
  answer = agent.run(SEM_PROMPT.gsub('{{OBJECTS}}', objects.inspect).gsub('{{TEXT}}', input)).to_s
  extract_json(answer.sub(/Final Answer:?\s*/i, '').strip)
end

def extract_json(text)
  l = text.rindex('{')
  r = text.rindex('}')
  return nil unless l && r && r > l
  JSON.parse(text[l..r])
rescue JSON::ParserError
  nil
end

# 机层重跑：给定约束/head，判断该例故障类型
def diagnose_example(ex, input, objects, target_obj, target_letter, n, offline)
  if offline
    cons = ex['cons'] || ex['constraints']
    head = ex['head']
    return { fixable: false, diag: 'gradebook 无约束快照（需真机）' } if cons.nil?
  else
    data = semantic_layer(objects, input)
    return { fixable: false, diag: 'VOID（语义层空）' } unless data
    cons = data['constraints']
    head = data['head']
  end
  m = load_machine_layer
  orders = begin
    m.solve_orders(objects, cons, head)
  rescue StandardError => e
    return { fixable: true, diag: "crash #{e.message[0, 60]}", constraints: cons, head: head,
             hint: "solve_orders 抛异常，机层需要修" }
  end
  if orders.empty?
    return { fixable: true, diag: '约束矛盾（无误模型）', constraints: cons, head: head,
             hint: "solve_orders 返回空——约束自相矛盾，机层/语义层必有一个翻方向" }
  end
  if orders.size > 1
    return { fixable: true, diag: "非唯一解（#{orders.size}）", constraints: cons, head: head,
             hint: "约束不足够唯一化 —— 语义层漏抽或机层归一漏了" }
  end
  opts = m.parse_options(input, objects, head)
  t = opts[target_letter] || {}
  target_obj ||= t[:obj]                # 官方 target 只有字母，对象来自选项回配
  if t[:rank].nil? || t[:obj].nil?
    return { fixable: true, diag: '选项未覆盖（rank_for 抽不出）', constraints: cons, head: head,
             hint: "rank_for 对 #{t[:text].inspect} 定位失败 —— 机层 rank_for 需修" }
  end
  machine = orders.first[m.target_pos(t[:rank], t[:side], n) - 1]
  return { fixable: true, diag: "方向 miss（machine=#{machine} != target=#{target_obj}）",
           constraints: cons, head: head, hint: "rank_for/target_pos/head 方向可能翻错" } unless machine == target_obj

  { fixable: false, diag: 'PASS（机层修复已验证通过）' }
end

# 修复轮：锁锚 + 诊断输入 + 改机层 + verify
def repair_task(example, ex, input, objects, target_obj, target_letter, status)
  cons_txt = (status[:constraints] || []).inspect
  <<~TASK
    你是 BBH·logical_deduction 的"机层修复专家"。系统把语义层抽出的约束交给机层
    （bbh 插件，plugins/bbh.rb 的纯确定性 Ruby）枚举全排列，但本题 FAIL 了。
    你的靶子是 bbh 插件的方法（read_code/apply_code/verify 可用，别碰语义层）。
    可用方法：solve_orders / satisfies? / target_pos / rank_for / parse_options /
    normalize_arg / idx / objlist_from / object_count。

    题面（对象 #{objects.inspect}）：
    #{input}

    目标选项 #{target_letter}，目标对象 #{target_obj.inspect}。
    语义层抽取约束：#{cons_txt}
    head=#{status[:head].inspect}
    故障诊断：#{status[:diag]}
    #{status[:hint] ? "修复提示：#{status[:hint]}" : ''}

    流程（务必遵守）：
    1) 先用 verify 锁锚，把"这道题必须为真"的最小事实钉死（example:
       verify solve_orders 在约束 #{cons_txt} 下结果非空；或 verify satisfies? 单条
       约束对局部全序的判断）。未锁锚不许碰代码——防止你误译语义。
    2) read_code 检查相关方法（先 library 看签名；怀疑方向 → satisfies?/target_pos/
       rank_for；怀疑多解 → solve_orders/normalize_arg；怀疑选项 → parse_options）。
    3) 只改你确认有缺陷的地方，apply_code 提交，再 verify 同一锚点确认改动不破坏它。
       若验证返回【已自动回滚】，说明你把对的改错了，回读源码重想。
    4) 用 learn 把这次诊断/修复教训沉淀（tags: bbh）。
    5) Final Answer 总结：改了哪个方法、verify 结果、重跑后解是否唯一且命中 target。
  TASK
end

def main
  path = ARGV.find { |a| !a.start_with?('--') }
  gb = (i = ARGV.index('--gradebook')) ? ARGV[i + 1] : nil
  max_fail = (j = ARGV.index('--max-fail')) ? ARGV[j + 1].to_i : 3
  offline = ARGV.include?('--offline')

  abort "缺数据文件" if path.nil? || !File.exist?(path)
  data = JSON.parse(File.read(path))
  examples = data['examples']

  grade = gb ? JSON.parse(File.read(File.join(ROOT, gb))) : nil
  fails = if grade
    grade['rows'].select { |r| r['verdict'] == 'FAIL' }.first(max_fail)
  else
    []
  end
  abort "gradebook 里没有 FAIL 例" if fails.empty?

  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('bbh', BBH_PLUGIN).load!)
  knowledge = RubyAgent::Knowledge.new(LESSONS)
  Dir.mkdir(GRADEBOCK, mode: 0o755) unless File.directory?(GRADEBOCK)

  repairer_builder = proc do
    RubyAgent::AgentLoop.new(
      hub: hub, llm: llm_adapter, max_steps: 12,
      writable_plugins: ['bbh'], knowledge: knowledge
    )
  end
  loop = RubyAgent::IterationLoop.new(hub: hub, knowledge: knowledge, builder: repairer_builder)

  # 阶段1：语义层重跑每个 FAIL（真机取约束）
  pre = fails.map do |ex|
    idx = ex['idx']
    example = examples[idx]
    input = example['input']
    n = (m = input.match(/set of (three|five|seven) objects/)) &&
        { 'three' => 3, 'five' => 5, 'seven' => 7 }[m[1]] || 3
    objects = load_machine_layer.objlist_from(input).first(n)
    tl = example['target'][/\(([A-G])\)/, 1]
    tgt = example['target'][/\([A-G]\)\s*(.*)/, 1].to_s.strip
    tgt = nil if tgt.empty?             # 官方只有 (D)，对象靠选项文字回配
    status = diagnose_example(ex, input, objects, tgt, tl, n, offline)
    { idx: idx, example: example, input: input, objects: objects, target_letter: tl,
      target_obj: tgt, status: status }
  end

  fixable = pre.select { |p| p[:status][:fixable] }
  puts "═══ RA 自迭代 BBH：FAIL #{fails.size}（fixable #{fixable.size}）═══"

  # 阶段2：IterationLoop 逐例修复（fixable 才需要动机层）
  results = []
  repair_tasks = fixable.map { |p| repair_task(p[:example], p[:status], p[:input], p[:objects], p[:target_obj], p[:target_letter], p[:status]) }
  loop.run(repair_tasks)

  loop.agents.each_with_index do |agent, i|
    p = fixable[i]
    next unless p
    re = diagnose_example(p[:status], p[:input], p[:objects], p[:target_obj], p[:target_letter], 0, true)
    re = diagnose_example(p[:status], p[:input], p[:objects], p[:target_obj], p[:target_letter],
                          p[:objects].size, false)
    fixed = re[:diag] =~ /PASS/
    results << { idx: p[:idx], diag: p[:status][:diag], fixed: !!fixed, verify: re[:diag] }
    puts "\n[#{i + 1}/#{fixable.size}] #%03d %s → %s" % [p[:idx], p[:status][:diag], fixed ? 'FIXED' : re[:diag]]
  end
  pre.select { |x| !x[:status][:fixable] }.each { |p| results << { idx: p[:idx], diag: p[:status][:diag], fixed: false } }

  puts "\n═══ RA 自迭代结果 #{results.count { |r| r[:fixed] }}/#{results.size} FIXED ═══"
  art = File.join(GRADEBOCK, "bbh_selfiterate_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(art, JSON.pretty_generate(generated_at: Time.now.iso8601, results: results))
  puts "  存档: #{art}"
end

main if $PROGRAM_NAME == __FILE__