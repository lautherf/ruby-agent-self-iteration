$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'ruby_agent/prop_solver'
require 'json'
require 'time'

# SOP-NL-02《自然语言隐藏前提·形式化验证》
#
# 思想（Lean 式 SOP）：不追求让"AI 自报隐藏前提"这种开放答案——而是把整条流程做成工序：
#   ① LLM 把自然语言的显式前提/结论翻译成命题逻辑 AST（人话→形式）
#   ② 机器用真值枚举 **证明**：这些前提到底推不推得出结论
#   ③ 若推不出，机器给出反例指派（模型）——被偷换/缺失的隐藏前提就精确地藏在这里
#   ④ 全自动判分：机器判定 vs 句子真实地位（正负误差可审计，没有人眼掺水）
#
# 判分（全机）：
#   PASS = 机器对 LLM 产物的推演结果 == 该句的真实地位，且 LLM 自报地位 == 机器推演
#   FAIL = 形式化失败（变量/连接词乱、机器判定偏离真实地位）或自报与实际不符
# 成绩存档 examples/gradebook/sop_verify_<ts>.json —— 这是"隐藏前提"第一次有可复验成绩。
#
# 用法：
#   ruby -Ilib examples/sop_verify.rb --dry   # 打印题面不烧 LLM
#   ruby -Ilib examples/sop_verify.rb         # 全量 4 题
ROOT = File.expand_path('..', __dir__)
warn "[sop_verify] __dir__=#{__dir__} ROOT=#{ROOT}" if ENV['SOP_DEBUG']

# 做题引擎立意：每句一个明确"真实地位"（expected）
#  - :entailed     显式前提已足够，结论成立的事实（机器给证明）
#  - :not_entailed 显式前提推不出结论（机器给反例 → 缺失前提所在地）
SOP_NL_02_CASES = [
  {
    name: 'rain-affirm-consequent',
    title: "肯定后件谬误",
    text: '如果下雨路就滑，今天路滑，所以今天下雨了。',
    expected: :not_entailed,
    note: '推理式：A=下雨,B=路滑。前提 A→B, B；结论 A。A→B ∧ B ⊬ A（反例：地滑却未下雨）。'
  },
  {
    name: 'candy-cure-single-cause',
    title: '单因谬误（因果独断）',
    text: '他吃了糖之后病好了，所以糖治好了他的病。',
    expected: :not_entailed,
    note: '显式前提：病好了(B)。结论：糖治病(A→B)。B ⊬ A→B（反例：吃糖且没好，即糖无效病自然好）。'
  },
  {
    name: 'oxygen-composition-probability',
    title: '组成 vs 概率（偷换分母）',
    text: '氧气占空气的五分之一，所以每次呼吸你有五分之四的概率憋死。',
    expected: :not_entailed,
    note: '显式前提：空气含氧(A)、呼吸需要氧(B)。结论：憋死(C)。A ∧ B ⊬ C（缺 D：一次呼吸是否用完氧气）。'
  },
  {
    name: 'early-ponens',
    title: '有效推理对照（正例）',
    text: '起得早就能多干一件事（P→Q），今天他起得早（P），所以他多干了一件事（Q）。',
    expected: :entailed,
    note: '有效三段论对照：P→Q, P ⊨ Q，机器应给"无反例"证明。'
  },
  {
    name: 'all-men-swap',
    title: '量词倒置（限量对调）',
    text: '所有男人都会死，所以，所有会死的都是男人。',
    expected: :not_entailed,
    note: 'A=男人,B=会死。显式前提 A→B（男人→会死）；结论 B→A（会死→男人）。A→B ⊬ B→A（反例：A=false,B=true——有会死的非男人）。'
  },
  {
    name: 'socratic-mortal',
    title: '有效实例化对照（正例补）',
    text: '所有人都会死，苏格拉底是人，所以苏格拉底会死。',
    expected: :entailed,
    note: 'M=是人,D=会死。前提 M→D, M；结论 D。⊨ 成立（标准三段论实例化）。'
  },
  {
    name: 'survivor-bias',
    title: '幸存者偏差（筛选样本）',
    text: '返航的战斗机机翼弹孔最多，说明应该给机翼装更多装甲——因为没回来的飞机都打在了别处。',
    expected: :not_entailed,
    note: 'H=机翼弹孔多,B=飞机活着返航,F=该部位是致命伤。显式前提只给了观察（H 与 B 相关）；结论"该部位致命/需加强"推不出——缺的前提：死在别处的样本从未计入（幸存者偏差）。'
  },
  {
    name: 'failure-proverb',
    title: '谚语全称滥用（过度因果必然化）',
    text: '失败是成功之母，他失败了很多次，所以他一定会成功。',
    expected: :not_entailed,
    note: '显式前提只有"他失败了很多次"(F)；结论"他成功"(E)。F ⊬ E——谚语是倾向性因果不是必然律，把"母亲"全称必然化正是隐藏前提。'
  }
].freeze

AST_RULES = <<~TXT
  把下面的自然语言句子翻译成命题逻辑 AST（只表达显式说出的前提与结论，不补"隐藏前提"）：
  变量用大写字母（最多 3 个），每个变量注释代表一个明确命题。
  连接词白名单（严禁自创）：["not",X] 非X；["and",X,Y] X且Y；["or",X,Y] X或Y；["imp",X,Y] 若X则Y；["iff",X,Y] X当且仅当Y
  全称句处理：句子含"所有人/所有X"时，把全称**实例化到句中那个个体**——如"所有人会死，苏格拉底是人"→ 前提 [["imp","S","D"],"S"]、结论 "D"（S=苏格拉底是人,D=苏格拉底会死）。
  conclusion 必须直译原句"所以"右半句，不得与任一前提同义复制，也不得改换原句的因果含义。
  claimed 必须先自检：在你自己给出的前提组合下，是否存在"前提全真而结论假"的指派——不存在才可写 entailed。
  时序/概率/程度等语义，一律用变量的布尔组合忠实表达，禁自创操作符。
  输出纯 JSON（勿多余文字）：
  {"vars":["A","B"],"premises":[["imp","A","B"],"B"],"conclusion":"A",
   "claimed":"not_entailed"}
  claimed 只能是 "entailed" 或 "not_entailed"。
  ⚠ 不许用工具，不许查库，直接纯思考试卷作答。
TXT

SOP_PROMPT = <<~PROMPT
  #{AST_RULES}
  句子：{{TEXT}}
  ⚠ 你必须用 Action=Final Answer 工具提交，Action Input 填你的 JSON（不要直接输出文本，否则答案不被系统收集）。
PROMPT

# —— JSON 抽取：取最后一个 '{' 到最后一个 '}' ——
def extract_json(text)
  l = text.rindex('{')
  r = text.rindex('}')
  return nil unless l && r && r > l

  JSON.parse(text[l..r])
rescue JSON::ParserError
  nil
end

def build_agent(lessons)
  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, lessons.path).load!)
  hub.mount(RubyAgent::DocPlugin.new('ra', File.expand_path('plugins/ra.rb', ROOT)).load!)
  llm = RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
  knowledge = RubyAgent::Knowledge.new(lessons.path)
  RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge,
                           max_steps: 8, writable_plugins: ['ra'], mode: :exam)
end

def vuln_label(machine_entailed)
  machine_entailed ? 'entailed' : 'not_entailed'
end

def run_case(t, lessons)
  3.times do |attempt|
    answer = begin
      build_agent(lessons).run(SOP_PROMPT.gsub('{{TEXT}}', t[:text])).to_s
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 80]}"
    end
    answer = answer.sub(/Final Answer:?\s*/i, '').strip
    next if answer.empty?

    data = extract_json(answer)
    return [answer, data] unless data.nil?

    puts "    ⚠ #{t[:name]} 第#{attempt + 1}次 JSON 解析失败，重试…" if attempt < 2
  end
  ['', nil]
end

if ARGV.include?('--dry')
  puts 'DRY：不调用 LLM。'
  SOP_NL_02_CASES.each do |t|
    puts "  #{t[:name]} [#{t[:title]}] expected=#{t[:expected]}\n    #{t[:text]}"
  end
  exit 0
end

abort '需要 AGNES_API_KEY' if ENV['AGNES_API_KEY'].to_s.empty?

lessons = RubyAgent::Knowledge.new(File.expand_path('examples/lessons.rb', ROOT))

rows = SOP_NL_02_CASES.map do |t|
  answer, data = run_case(t, lessons)

  if data.nil?
    puts "  VOID  #{t[:name]}   空交卷或 JSON 解析失败 → #{answer[0, 80]}"
    next { name: t[:name], verdict: 'VOID', answer: answer[0, 120] }
  end

  starts = data['vars']&.map(&:to_s) || []
  premises = data['premises'] || []
  conclusion = data['conclusion']
  claimed = data['claimed'].to_s

  machine = begin
             if !premises.empty? && !conclusion.nil?
               PropSolver.verify(premises, conclusion)
             else
               { entailed: false, countermodels: [], schema_error: true }
             end
           rescue StandardError => e
             { entailed: false, countermodels: [], schema_error: true, crash: e.message[0, 80] }
           end
  machine_label = machine[:schema_error] ? "schema_error#{machine[:crash] ? "（#{machine[:crash]}）" : ''}" : vuln_label(machine[:entailed])
  expected_label = vuln_label(t[:expected] == :entailed)

  matched = machine_label == expected_label && !machine[:schema_error]
  aligned = claimed == machine_label
  verdict = matched && aligned ? 'PASS' : 'FAIL'

  diag = if machine[:schema_error]
           '产物缺 premises/conclusion'
         elsif !matched
           "机器判 #{machine_label} ≠ 真实地位 #{expected_label}"
         elsif !aligned
           "LLM 自报 #{claimed.inspect} ≠ 机器推演 #{machine_label}"
         else
           '一致'
         end
  puts "  #{verdict}  #{t[:name]} [#{t[:title]}] expected=#{expected_label} 判定=#{machine_label} 自报=#{claimed}（#{diag}）"
  machine[:countermodels].first(2).each do |cm|
    puts "    └ 机器反例模型: #{PropSolver.describe_model(cm)}（这些指派里前提皆真而结论假 → 缺的前提在别处）"
  end
  { name: t[:name], verdict: verdict,
    expected: expected_label, machine: machine_label, claimed: claimed,
    answer: answer[0, 200], diag: diag }
end

passed = rows.count { |r| r[:verdict] == 'PASS' }
failed = rows.count { |r| r[:verdict] == 'FAIL' }
void = rows.count { |r| r[:verdict] == 'VOID' }
puts
puts '════════ SOP-NL-02 形式化验证 ════════'
puts "  PASS #{passed} / FAIL #{failed} / VOID #{void}（共 #{SOP_NL_02_CASES.size}）"
puts "  机器证明全部离线完成；PASS = 机器推演命中真实地位 且 LLM 自报与机器一致"
puts '  证据链：LLM 只做翻译，证明与反例全由 PropSolver 真值枚举出具——这就是 Lean 思想的工序。'

Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
artifact = File.join(ROOT, 'examples', 'gradebook', "sop_verify_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
File.write(artifact, JSON.pretty_generate(
  generated_at: Time.now.iso8601,
  model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
  sop: 'SOP-NL-02', total: SOP_NL_02_CASES.size,
  passed: passed, failed: failed, void: void, rows: rows
))
puts "  证据存档: #{artifact}"