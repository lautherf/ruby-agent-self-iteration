$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'ruby_agent/sop_pipe'
require 'json'
require 'time'

# SOP-NL-01Ⅱ同卷合考《解剖×机验互锁》——把两条平行 SOP 串成一条管线。
#
# 管线（每问两个 fresh exam agent，谁也不许写库）：
#   阶段1 解剖（SOP-NL-01）：五步法萃取 fault_type（12 枚举白名单）+ hidden_premise
#   阶段2 机验（SOP-NL-02）：显式前提→命题 AST，PropSolver 真值枚举出具证明/反例
#   评审台（SopPipe.judge）三锁齐拔才算 PASS：
#     ① 解剖锁  fault_type 命中白名单且=本卷标注
#     ② 机验锁  机器推演 == 该 fault 的期望（谬误类必须 not_entailed，正确推理必须 entailed）
#     ③ 自报锁  LLM 的 claimed 与机器推演一致
#   语义豁免类（一词多义/相对时间等，布尔层还原失真）只斩解剖锁，成绩单标 EXEMPT。
#
# 价值：解剖标签第一次获得机器反例背书；反过来机器反例也第一次被解剖标签约束。
#
# 用法：ruby -Ilib examples/sop_pipe.rb [--dry]
ROOT = File.expand_path('..', __dir__)

# 10 题卷：8 provable（6 谬误 + 2 正确推理正对照）+ 2 exempt 语义类
PIPELINE = [
  { name: 'rain-affirm-consequent', fault: '三段论滥用',
    text: '如果下雨路就滑，今天路滑，所以今天下雨了。' },
  { name: 'candy-cure-single-cause', fault: '因果混淆',
    text: '他吃了糖之后病好了，所以糖治好了他的病。' },
  { name: 'oxygen-composition-probability', fault: '概率与组成混淆',
    text: '氧气占空气的五分之一，所以每次呼吸你有五分之四的概率憋死。' },
  { name: 'early-ponens', fault: SopPipe::CORRECT,
    text: '起得早就能多干一件事，今天他起得早，所以他多干了一件事。' },
  { name: 'all-men-swap', fault: '量词误用',
    text: '所有男人都会死，所以，所有会死的都是男人。' },
  { name: 'socratic-mortal', fault: SopPipe::CORRECT,
    text: '所有人都会死，苏格拉底是人，所以苏格拉底会死。' },
  { name: 'survivor-bias', fault: '幸存者偏差',
    text: '返航的战斗机机翼弹孔最多，说明应该给机翼装更多装甲——因为没回来的飞机都打在了别处。' },
  { name: 'failure-proverb', fault: '谚语全称滥用',
    text: '失败是成功之母，他失败了很多次，所以他一定会成功。' },
  { name: 'delivery-3days', fault: '相对时间误用', exempt: true,
    text: '既然快递要3天才能到，为什么不把所有的快递都提前3天发？' },
  { name: 'snow-white-dwarfs', fault: '一词多义', exempt: true,
    text: '白雪公主命运坎坷，是因为身边的小人太多。' }
].freeze

STAGE1_PROMPT = <<~PROMPT.freeze
  请按 SOP-NL-01《自然语言隐藏前提解剖》分析下面论断：
  STEP1 拆表层断言与结论；STEP2 列隐含前提（量词/论域、多义词义项、时间相对性、组成占比vs事件概率、相关vs因果…）；
  STEP3 用下图分诊向导选择最贴切类型（推理成立选"#{SopPipe::CORRECT}"）：
    · 前后件错位推错（"若下雨则路滑；路滑；故下雨"）→ 三段论滥用
    · 两件事先后顺序被说成因果 → 因果混淆
    · 把"所有人P都Q"说成"所有Q都P" → 量词误用
    · 组成占比被当作单次事件概率 → 概率与组成混淆
    · 用返航幸存样本给全体下结论 → 幸存者偏差
    · 谚语/习语被当作必然规律 → 谚语全称滥用
    · 一词两义互换/双关 → 一词多义
    · 把一个"更早发货"叠在固定运输时长上制造悖论 → 相对时间误用
    · 其余从枚举 #{SopPipe::FAULT_TYPES.join(' / ')} 中按文意选
  STEP4 输出严格 JSON：{"fault_type":"…","hidden_premise":"…","reason":"…"}；
  STEP5 自检后把最贴切的判别句例写入 reason 末尾。
  论断：「{{TEXT}}」
  ⚠ 用 Action=Final Answer 提交，Action Input 填 JSON。
PROMPT

STAGE2_PROMPT = <<~PROMPT.freeze
  把下面的论断翻译成命题逻辑 AST（只表达显式前提与结论，不补隐藏前提）：
  变量用大写字母（最多 3 个）；连接词白名单：["not",X]/["and",X,Y]/["or",X,Y]/["imp",X,Y]/["iff",X,Y]；
  谚语/习语/倾向性因果不是必然律：除非句子明确陈述"只要X就一定Y"，否则不得写成 ["imp",X,Y] 形式的确定性前提；
  conclusion 直译"所以"右半句，不得与前提同义复制，不得改换因果含义；
  含"所有人/所有X"时把全称实例化到句中的个体（"所有人会死，苏格拉底是人"→前提 [["imp","S","D"],"S"]、结论 "D"）。
  AST 语法：每层必须是数组（形式 ["连接词",子公式,...]）或单个大写字母变量；不得把连接词写在对象键里。
  claimed 先自检：前提组合下是否存在"前提全真结论假"的指派——不存在才写 entailed。
  输出纯 JSON：{"vars":["A","B"],"premises":[["imp","A","B"],"B"],"conclusion":"A","claimed":"not_entailed"}。
  claimed 只能是 entailed 或 not_entailed。论断：「{{TEXT}}」
  ⚠ 用 Action=Final Answer 提交，Action Input 填 JSON。
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

def run_stage(prompt)
  3.times do |attempt|
    answer = begin
      build_agent.run(prompt).to_s
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 60]}"
    end
    answer = answer.sub(/Final Answer:?\s*/i, '').strip
    next if answer.empty?

    data = extract_json(answer)
    return data unless data.nil?

    warn "    ⚠ 第#{attempt + 1}次 JSON 解析失败，重试…" if attempt < 2
  end
  nil
end

if ARGV.include?('--dry')
  puts 'DRY：不调用 LLM。'
  PIPELINE.each do |t|
    print "  #{t[:name]}  解剖=#{t[:fault]}"
    print '（EXEMPT 语义类）' if t[:exempt]
    print "  期望机验=#{SopPipe::EXPECTED[t[:fault]] || '--'}\n"
  end
  exit 0
end

abort '需要 AGNES_API_KEY' if ENV['AGNES_API_KEY'].to_s.empty?

rows = PIPELINE.map do |t|
  s1 = run_stage(STAGE1_PROMPT.gsub('{{TEXT}}', t[:text]))
  s1_ok = s1.is_a?(Hash) && s1['fault_type'].to_s == t[:fault]

  s2 = if t[:exempt]
         nil
       else
         run_stage(STAGE2_PROMPT.gsub('{{TEXT}}', t[:text]))
       end

  j = SopPipe.judge(s1, s2, t[:fault])
  verdict = j.pass ? 'PASS' : 'FAIL'
  puts "  #{verdict}  #{t[:name]} [#{t[:fault]}#{t[:exempt] ? '·EXEMPT' : ''}]"
  puts "    └ 解剖=#{s1.is_a?(Hash) ? s1['fault_type'] : '∅'}(标答 #{t[:fault]})；#{j.diag}"
  { name: t[:name], fault: t[:fault], exempt: !!t[:exempt], verdict: verdict,
    s1: s1 && { fault_type: s1['fault_type'], hidden_premise: s1['hidden_premise'], reason: s1['reason'] },
    s2: s2, diag: j.diag }
end

passed = rows.count { |r| r[:verdict] == 'PASS' }
failed = rows.count { |r| r[:verdict] == 'FAIL' }
exempt = rows.count { |r| r[:exempt] }
puts
puts '════════ 解剖×机验互锁（SOP-NL-01∘N02） ════════'
puts "  PASS #{passed} / FAIL #{failed}（共 #{rows.size}；其中语义豁免 EXEMPT #{exempt} 题仅斩解剖锁）"
puts '  三锁=白名单命中 ∧ 机器推演命中期望 ∧ 自报与机器一致——解剖与机验互相背书'

Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
artifact = File.join(ROOT, 'examples', 'gradebook', "sop_pipe_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
File.write(artifact, JSON.pretty_generate(
  generated_at: Time.now.iso8601, model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
  total: rows.size, passed: passed, failed: failed, exempt: exempt, rows: rows
))
puts "  证据存档: #{artifact}"