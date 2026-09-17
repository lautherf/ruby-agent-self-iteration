# frozen_string_literal: true

# RA 成长闭环：让语义层 Agent 自己用错题解题 + 自省沉淀，教训注入下一轮。
#
# 与 bbh_self_fix_demo（修 harness）不同，这是"语义层成长"：
# 机层（solve_orders 等纯函数）已经正确，错因在语义层方向/漏约束。
# 于是循环主体是 RA 的 Agent（非 exam，可 learn），每一轮：
#   1. 带当前 knowledge（含已沉淀教训）做一道真实 FAIL 错题，只输出 JSON 约束；
#   2. 外部机层验证 → PASS 记一例，FAIL/多解/矛盾则把诊断注入下一轮 task；
#   3. Agent 被允许 learn，教训自动进 knowledge → 下一轮 for_llm 自动带上；
#   4. 观察同组错题的命中率是否随轮次单调提升 —— 这就是 RA 在成长。
#
# 用法：
#   AGNES_API_KEY=sk-... ruby -Ilib examples/bbh_grow.rb \
#     /tmp/opencode/bbh/logical_deduction_five_objects.json \
#     --gradebook examples/gradebook/bbh_five_merged_20260916.json \
#     [--rounds 4] [--per-round 3] [--head-hint 1]

require 'json'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ROOT = File.expand_path('..', __dir__)
BBH_PLUGIN = File.join(ROOT, 'plugins', 'bbh.rb')
LESSONS = File.join(ROOT, 'examples', 'lessons.rb')

def machine
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

def extract_json(text)
  l = text.rindex('{')
  r = text.rindex('}')
  return nil unless l && r && r > l
  JSON.parse(text[l..r])
rescue JSON::ParserError
  nil
end

# 机层验证一组约束：返回 :pass / :multi(n) / :contra / :miss/ :option
def machine_verify(objects, constraints, head, input, target_letter, target_obj, m)
  orders = begin
    m.solve_orders(objects, constraints, head)
  rescue StandardError => e
    return { ok: false, kind: :crash, msg: e.message[0, 60] }
  end
  return { ok: false, kind: :contra, msg: '约束矛盾（无误模型）' } if orders.empty?
  if orders.size > 1
    return { ok: false, kind: :multi, msg: "非唯一解（#{orders.size}）" }
  end
  opts = m.parse_options(input, objects, head)
  t = opts[target_letter] || {}
  return { ok: false, kind: :option, msg: "选项未覆盖（选项 #{target_letter} 解析失败）" } if t[:rank].nil? || t[:obj].nil?

  machine = orders.first[m.target_pos(t[:rank], t[:side], objects.size) - 1]
  machine == target_obj ? { ok: true, kind: :pass } : { ok: false, kind: :miss, msg: "machine=#{machine}!=#{target_obj}" }
end

# 组装一轮的 Agent 任务：错题正文 + 上轮诊断 + 期望动作
def task_for(example, objects, target_letter, target_obj, round_no, last_state, head_hint)
  last_summary = if last_state[:pass]
                   "上轮你已解对。请保持同样思路输出约束，但可再优化让机层判断干脆。"
                 elsif last_state[:diag]
                   "上轮机层诊断：#{last_state[:diag]}。本轮必须改对。若这是方向/约束错误，先想清
                   序向后请务必用 learn 沉淀一条教训（一条即可，讲清这类题的错因与对法），
                   下次同类题你会带上它。"
                 else
                   '（首轮，无上轮诊断）'
                 end
  last_summary.gsub!(/\n+/, ' ')
  hint = ''
  if head_hint
    hint = <<~HINT

      方向约定（务必遵守）：题干里"more/newer/above/first…"这类"更/新/高/前"语义用 before（排更前），
      反义"older/cheaper/below/last…"用 after。head 概念与 before 方向必须一致——
      若你判定 before=更旧，head 应声明 old。方向判断错了整题必错，动手前先想清楚序向。
    HINT
  end
  <<~TASK
    【第 #{round_no} 轮】你是 BBH·logical_deduction 的"升维语义层"。把自然语言排序题的
    比较/位置关系句抽成标准谓词 JSON，机层会穷举验证唯一解。

    对象清单（机器已解析，引用必须一字不差，含冠词）：
    #{objects.inspect}

    题干：
    #{example['input']}

    目标选项 #{target_letter}，官答对象 #{target_obj.inspect}（机层会用它验证你）。
    #{hint}

    上次你给出的约束在这道题上的机层诊断（本轮必须改对，除非已是 PASS）：
    #{last_summary}

    输出纯 JSON（这就是你的 Final Answer，Action Input 提交）：
    {"objects":[...],"constraints":[["before","X","Y"],...],"head":"left"}
    唯一约束种类：["before","X","Y"] / ["after","X","Y"] / ["adjacent","X","Y"] /
    ["between","X","Y","Z"] / ["rank","X",k,"left"]（物理方位）/
    ["rank","X",k,"old"/"new"/"expensive"/"cheap"/"first"]（概念端点）。
    你可以先 read_docs 看这台机器历次自省沉淀的教训（learn 过的都会在里面）；
    也可以用 learn 把本轮的错因/正确姿势沉淀进知识库（下轮自动带上）。
    只许输出 JSON，不要解释。若你能确定正确约束就让机层唯一命中 #{target_letter}。
  TASK
end

def main
  path = ARGV.find { |a| !a.start_with?('--') }
  gb = (i = ARGV.index('--gradebook')) ? ARGV[i + 1] : nil
  rounds = (j = ARGV.index('--rounds')) ? ARGV[j + 1].to_i : 4
  per_round = (k = ARGV.index('--per-round')) ? ARGV[k + 1].to_i : 3
  head_hint = ARGV.include?('--head-hint')

  abort "缺数据文件" if path.nil? || !File.exist?(path)
  abort "需 --gradebook（本闭环从 FAIL 样本出发）" if gb.nil? || !File.exist?(File.join(ROOT, gb))
  data = JSON.parse(File.read(path))
  examples = data['examples']

  grade = JSON.parse(File.read(File.join(ROOT, gb)))
  fail_rows = if grade
    grade['rows'].select { |r| r['verdict'] == 'FAIL' }
  else
    []
  end
  fail_rows = fail_rows.sort_by { |r| r['idx'] }
  abort "gradebook 无 FAIL 样本" if fail_rows.empty?
  picked = fail_rows.first(per_round)

  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('bbh', BBH_PLUGIN).load!)
  knowledge = RubyAgent::Knowledge.new(LESSONS)
  hub.mount(RubyAgent::DocPlugin.new('knowledge', LESSONS).load!)

  # 每轮样本循环（同一个 hub/knowledge 共享，learn 沉淀进知识，下轮 for_llm 带上）
  puts "═══ RA 成长闭环：#{picked.size} 个错题 × #{rounds} 轮 ═══"
  history = {}
  rounds.times do |r|
    round_no = r + 1
    ok_n = 0
    picked.each_with_index do |row, i|
      idx = row['idx']
      example = examples[idx]
      input = example['input']
      n = (mm = input.match(/set of (three|five|seven) objects/)) &&
          { 'three' => 3, 'five' => 5, 'seven' => 7 }[mm[1]] || 3
      objects = machine.objlist_from(input).first(n)
      target_letter = example['target'][/\(([A-G])\)/, 1]
      target_obj = begin
        m = machine
        m.parse_options(input, objects, 'left')[target_letter][:obj]
      rescue StandardError
        example['target'][/\([A-G]\)\s*(.*)/, 1].to_s.strip
      end

      key = idx
      prev = history[key] || {}
      diag = prev[:diag]
      # 每轮 reload：learn 写入的教训实时进 for_llm
      hub.get('knowledge')&.load!
      agent = RubyAgent::AgentLoop.new(
        hub: hub, llm: llm_adapter, max_steps: 8,
        knowledge: knowledge
      )
      agent.on(:learn) { |e| puts "      ★ RA 沉淀 #{e[:id]}" }
      agent.on(:tool_call) { |e| puts "      → #{e[:tool]}" }
      answer = agent.run(task_for(example, objects, target_letter, target_obj, round_no,
                                  { diag: diag }, head_hint))
      parsed = extract_json(answer.to_s)
      outcome = if parsed && parsed['constraints'].is_a?(Array)
        machine_verify(objects, parsed['constraints'], parsed['head'], input, target_letter, target_obj, machine)
      else
        { ok: false, kind: :crash, msg: 'JSON 解析失败' }
      end
      history[key] = { diag: "#{outcome[:kind]}#{outcome[:msg] ? "（#{outcome[:msg]}）" : ''}" }
      ok_n += 1 if outcome[:ok]
      puts "  R#{round_no} #%03d #{outcome[:ok] ? '✓' : '✗'} #{outcome[:kind]} #{outcome[:msg].to_s[0, 40]}" % idx
    end
    puts "── Round #{round_no}: #{ok_n}/#{picked.size} PASS（累计教训 #{knowledge.lessons.size} 条）"
  end
  puts "═══ 成长完毕：知识库教训 #{knowledge.lessons.size} 条 ═══"
end

main if $PROGRAM_NAME == __FILE__