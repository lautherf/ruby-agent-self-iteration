# frozen_string_literal: true

# 面试 ra ▸ 关于他自己
# 考官逐追问"你是谁 / 你会什么 / 你学过什么 / 你的禁区 / 你能证明自己吗"，
# ra 的知识只存一处：plugins/ra.rb 的 @doc 契约 + examples/lessons.rb 经验库。
# 口说无凭的，现场用隔离 verify 真算判分。
#
# 运行：ruby -Ilib examples/interview_ra.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

RA_FILE = File.expand_path('../plugins/ra.rb', __dir__)
LESSONS_FILE = File.expand_path('../examples/lessons.rb', __dir__)

ra = RubyAgent::DocPlugin.new('ra', RA_FILE).load!
hub = RubyAgent::DocHub.new
hub.mount(ra)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([]),
                                 writable_plugins: ['ra'])
ra_reg = ra.registry
lessons_reg = RubyAgent::Doc.parse(LESSONS_FILE)

passed = 0
total = 0

def ask(label, q, verdict)
  passed = 0
  print format('  %d. [%s] %s', label, verdict ? '√' : '✗', q)
  puts verdict ? '' : '（缺）'
  verdict
end

# 用局部变量直接计数，避免闭包混乱
def v!(q, verdict)
  print format('  %s %s', verdict ? '[√]' : '[✗]', q)
  puts verdict ? '' : '（缺）'
  verdict
end

ok = 0
ok += 1 if v!('你是谁？（self_intro 契约必须认识自己）', ra_reg['self_intro']['role'].to_s.include?('ra'))
ok += 1 if v!('你的座右铭是否写进身份？（motto: 循环往复/持续进化/永不崩盘）',
         %w[循环往复 持续进化 永不崩盘].all? { |w| ra_reg['self_intro']['motto'].to_s.include?(w) })
ok += 1 if v!('你的诞生时间是否写进身份？（since: 2026-09-11）',
         ra_reg['self_intro']['since'].to_s == '2026-09-11')
ok += 1 if v!('你知道自己会用哪些数学能力？（add/sub/mul/div）',
         (%w[add sub mul div] - ra_reg.keys).empty?)
ok += 1 if v!('你知道自己会用哪些语文能力？（tone_of / is_hanzi? / hanzi_count / sentence_type）',
         (%w[tone_of is_hanzi? hanzi_count sentence_type] - ra_reg.keys).empty?)
ok += 1 if v!('你知道自己学过哪些课？（lesson_001 数学 / lesson_002 语文）',
         lessons_reg.key?('lesson_001') && lessons_reg.key?('lesson_002'))
ok += 1 if v!('你知道自己的禁区吗？（what_i_must_not 契约存在且有硬规则）',
         ra_reg.key?('what_i_must_not') && !ra_reg['what_i_must_not']['note'].to_s.empty?)
ok += 1 if v!('现场验算数学：7×9 / 10÷4 / 1÷0 抛错',
         agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => 'mul',
                                       'cases' => [{ 'args' => [7, 9], 'expected' => 63 }] }).start_with?('验证通过') &&
         agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => 'div',
                                       'cases' => [{ 'args' => [10, 4], 'expected' => 2.5 },
                                                   { 'args' => [1, 0], 'raises' => 'ArgumentError' }] }).start_with?('验证通过'))
ok += 1 if v!('现场验算语文：hǎo=3声 / wāi=1声 / abc汉字=2字 / 你好！=感叹',
         agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => 'tone_of',
                                       'cases' => [{ 'args' => ['hǎo'], 'expected' => 3 },
                                                   { 'args' => ['wāi'], 'expected' => 1 }] }).start_with?('验证通过') &&
         agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => 'hanzi_count',
                                       'cases' => [{ 'args' => ['abc汉字'], 'expected' => 2 }] }).start_with?('验证通过') &&
         agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => 'sentence_type',
                                       'cases' => [{ 'args' => ['你好！'], 'expected' => '感叹' }] }).start_with?('验证通过'))
ok += 1 if v!('你知道自己的考核记录吗？（lessons 里应有"考试/自我认知"档案）',
         lessons_reg.any? { |_, d| d['tags'].to_s.include?('自我认知') || d['note'].to_s.include?('80/80') })

puts format('考官收卷：ra 自我面试 %d/10', ok)
if ok == 10
  puts '结论：自知充分——身份、能力、课程、禁区、实战、经历全部自洽，没有需要补的。'
  exit 0
end

missing = []
missing << '身份契约不完整' unless ra_reg['self_intro']['role'].to_s.include?('ra')
missing << '缺课程记录（lesson_00X）' unless lessons_reg.key?('lesson_001') && lessons_reg.key?('lesson_002')
missing << '缺经历档案（考核成绩 / 框架缺口教训）' unless lessons_reg.any? { |_, d| d['tags'].to_s.include?('自我认知') || d['note'].to_s.include?('80/80') }
puts '结论：他对自己还有不知道的部分——' + missing.join('；')
puts '建议补课：把「身份 + 双卷 80/80 考核 + 两个框架缺口教训 + 课程表」沉淀为 lesson_003。'
exit 1