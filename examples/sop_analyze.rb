$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# =============================================================================
# SOP-NL-01 自然语言隐藏前提解剖（Standard Operating Procedure）
# -----------------------------------------------------------------------------
# 起源：弱智吧经典题逻辑解剖考 8/8 那套 prompt 的固化版本。
# 适用：任何"看似有理却自相矛盾 / 藏着前提 / 玩词义"的自然语言论断。
# 用法：
#   ruby -Ilib examples/sop_analyze.rb "你的论断或问题……"
#   ruby -Ilib examples/sop_analyze.rb --selftest   # 用弱智吧 8 真题回归本 SOP
# 原理：不新增 verify 方法（开放题没有唯一真值），而是把分析流程+
#       错位枚举+输出结构固化成模板 prompt，逐条套用、老师阅卷。
# =============================================================================

FAULT_ENUM = %w[
  互补分割误读 相对时间误用 幸存者偏差 定义循环 概率与组成混淆 组块歧义
  一词多义 谚语全称滥用 名实错位 量词误用 三段论滥用 因果混淆
].freeze

SOP_PROMPT = <<~PROMPT.freeze
  请按 SOP-NL-01《自然语言隐藏前提解剖》分析下面一段论断（文字游戏/自相矛盾/藏着前提）：
  必须严格执行五步流程——
  STEP1 拆句：先写出论断的表层断言与它想说出的"结论"。
  STEP2 列隐含前提：追问这段话要成立还偷偷需要哪些前提（量词/论域、多义词的哪个义项、
        时间与事件相对性、组成占比 vs 事件概率、名称与功能的错位、比喻被当成字面、
        比例与分割、定义等级的循环、相关被说成因果，等等）。
  STEP3 对表：从枚举中挑一个最贴切的错位类型：#{FAULT_ENUM.join(' / ')}。
  STEP4 输出（严格 JSON，不得带多余字段）：
        {"fault_type":"<STEP3 选的枚举>","hidden_premise":"一句话点破被偷换的隐藏前提","reason":"1-2 句说明错位如何发生"}
  STEP5 自检：若有歧义构造，用一句话的例子证明此事确实发生了错位（写入 reason 末尾）。
  论断：「{{TEXT}}」
PROMPT

ROOT = File.expand_path('..', __dir__)

# —— 弱智吧 8 真题（SOP 回归集，老师阅卷标注标准）——
REGRESSION = [
  ['地球上有70%的海洋和30%的陆地，那么剩下的30%海洋和70%的陆地去哪了？', '互补分割误读'],
  ['既然快递要3天才能到，为什么不把所有的快递都提前3天发？', '相对时间误用'],
  ['为啥长寿的碰巧都是老年人？', '定义循环'],
  ['氧气占空气体积的五分之一，所以每次呼吸都有五分之四的概率憋死。', '概率与组成混淆'],
  ['一个半小时是几个半小时？', '组块歧义'],
  ['白雪公主命运坎坷，是因为身边的小人太多。', '一词多义'],
  ['虎毒不食子，专家建议野外遇到老虎可跪下认爹。', '谚语全称滥用'],
  ['指南针明明是"指北"的，为什么叫"指南"针？', '名实错位']
].freeze

def build_agent
  ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', ROOT)).load!
  knowledge = RubyAgent::Knowledge.new(File.expand_path('../examples/lessons.rb', ROOT))
  hub = RubyAgent::DocHub.new
  hub.mount(ra)
  hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)
  llm = RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
  agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge, max_steps: 10, writable_plugins: ['ra'], mode: :exam)
end

def run_sop(agent, text)
  final = begin
    agent.run(SOP_PROMPT.gsub('{{TEXT}}', text)).to_s
  rescue StandardError => e
    "run 异常：#{e.class}: #{e.message[0, 80]}"
  end
  final.sub(/Final Answer:?/, '').gsub(/\s+/, ' ').strip
end

if ARGV.include?('--selftest')
  puts '【SOP-NL-01 回归】弱智吧 8 真题（老师阅卷看内容，标准类型见括号）'
  agent = build_agent
  REGRESSION.each_with_index do |(q, standard), qi|
    puts "  #{qi + 1}. #{q.slice(0, 24)}…  [标准:#{standard}]"
    puts "     → #{run_sop(agent, q).slice(0, 300)}"
    puts
  end
  puts '【回归结束】逐条对照标准人工判定'
else
  text = ARGV.join(' ')
  abort '用法：ruby -Ilib examples/sop_analyze.rb "论断"  或  --selftest' if text.strip.empty?

  agent = build_agent
  puts run_sop(agent, text)
end