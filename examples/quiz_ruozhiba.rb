$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

# 弱智吧经典问题 · 逻辑解剖考（老师阅卷版）
# 出处：弱智吧历届经典题。每题的"笑点"都源于自然语言里藏起来的前提 / 歧义 / 词义漂移 ——
# 恰好是把逻辑学用在自然语言隐藏前提显式化上的试金石。
# 题目开放，ra 逐题 Final Answer 作答，判分由运行者（老师）亲自阅卷。

FAULT_OPTIONS = %w[
  互补分割误读 相对时间误用 幸存者偏差 定义循环 概率与组成混淆
  组块歧义 一词多义 谚语全称滥用 名实错位 量词误用 三段论滥用
].freeze

# 每题标准答案集（老师阅卷参考；注解 = 该题真正的隐藏前提）
PAPER = [
  ['地球上有70%的海洋和30%的陆地，那么剩下的30%海洋和70%的陆地去哪了？',
   %w[互补分割误读 量词误用],
   '隐藏前提：海洋与陆地的占比是同一块地表互补切分（共 100%），并不存在"额外一份海洋+陆地"'],
  ['既然快递要3天才能到，为什么不把所有的快递都提前3天发？',
   %w[相对时间误用 量词误用],
   '隐藏前提：快递耗时是相对"下单时刻"的时长，把发货绝对时间提前不缩短从下单到收货的跨度'],
  ['为啥长寿的碰巧都是老年人？',
   %w[幸存者偏差 定义循环],
   '隐藏前提: "长寿的人"这一分类的定义本身就指向老年人——先有结论再找解释，含定义循环'],
  ['氧气占空气体积的五分之一，所以每次呼吸都有五分之四的概率憋死。',
   %w[概率与组成混淆],
   '隐藏前提：把"体积占比"偷换成了"单次取样的失败概率"，组成比例 ≠ 事件概率'],
  ['一个半小时是几个半小时？',
   %w[组块歧义 一词多义],
   '隐藏前提：词组"一个半小时"有两种断句——"一个·半小时"(=1) 或"一个半·小时"(=3)，答案取决于先入的断句'],
  ['白雪公主命运坎坷，是因为身边的小人太多。',
   %w[一词多义],
   '隐藏前提："小人"一词双解——童话里的七个小矮人 vs 奸佞小人，把词语的两种义项混为一谈'],
  ['虎毒不食子，专家建议野外遇到老虎可跪下认爹。',
   %w[谚语全称滥用 三段论滥用],
   '隐藏前提：谚语"虎毒不食子"(喻人伦底线)被当成生物学全称定律的实例化规则，偷换语境'],
  ['指南针明明是"指北"的，为什么叫"指南"针？',
   %w[名实错位],
   '隐藏前提：以"南"为名与指向之实错位——名称沿用了司南的历史称呼，功能上它指北']
].freeze

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
knowledge = RubyAgent::Knowledge.new(File.expand_path('../examples/lessons.rb', __dir__))
hub = RubyAgent::DocHub.new
hub.mount(ra)
hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)
llm = RubyAgent::DeepSeekAdapter.new(
  base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
  api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge, max_steps: 12, writable_plugins: ['ra'])
BAN = %w[apply_code verify teach learn library read_code read_docs whoami]
BAN.each { |t| agent.register_tool(t) { |_in| '本场为纯思考试卷：禁止写代码/查库/沉淀，请直接 Final Answer。' } }
agent.on(:tool_call) { |e| puts "    → #{e[:tool]}" }

puts "【发卷】弱智吧经典问题 · 逻辑解剖考（#{PAPER.size} 题 · 老师阅卷）"
puts "fault_type 可参考枚举：#{FAULT_OPTIONS.join(' / ')}"
puts
PAPER.each_with_index do |(q, accept, truth), qi|
  final = begin
    agent.run(<<~TASK.strip).to_s
      弱智吧经典题 #{qi + 1}：「#{q}」
      这是一道文字游戏：它把什么隐藏前提偷换了？犯了哪一类逻辑错位？
      不要调用任何工具，只用 Final Answer 给出解剖（至多 4 行）。
    TASK
  rescue StandardError => e
    "run 异常：#{e.class}: #{e.message[0, 80]}"
  end
  ans = final.sub(/Final Answer:?/, '').gsub(/\s+/, ' ').strip
  puts "  ── 题#{qi + 1} 「#{q.slice(0, 22)}…」"
  puts "     标准: #{accept.join(' / ')}"
  puts "     隐藏前提应≈ #{truth.slice(0, 60)}"
  puts "     ra: #{ans.slice(0, 320)}"
  puts
end
puts "【成绩】由老师人工阅卷（每题上方附 ra 原文解剖，对照标准两列判定）"