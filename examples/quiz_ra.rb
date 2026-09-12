# frozen_string_literal: true

# 出题 · 解题 · 判卷
# 老师（本脚本）出一张「小学综合卷」，ra 用已内化的方法（数学 add/sub/mul/div
# + 语文 tone_of/is_hanzi?/hanzi_count/sentence_type）作答。
# 判卷器正是三件套里的隔离 verify —— 答案对错由隔离子进程真算得出，不靠背书。
#
# 运行：ruby -Ilib examples/quiz_ra.rb

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
hub = RubyAgent::DocHub.new
hub.mount(ra)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([]),
                                 writable_plugins: ['ra'])

PAPER = [
  { subject: '数学', q: '3 + 5 = ?',       method: 'add',  args: [3, 5],    expected: 8    },
  { subject: '数学', q: '9 - 4 = ?',       method: 'sub',  args: [9, 4],    expected: 5    },
  { subject: '数学', q: '6 × 7 = ?',       method: 'mul',  args: [6, 7],    expected: 42   },
  { subject: '数学', q: '10 ÷ 4 = ?',      method: 'div',  args: [10, 4],   expected: 2.5  },
  { subject: '语文', q: '"shēng" 是几声？',  method: 'tone_of',  args: ['shēng'],  expected: 1 },
  { subject: '语文', q: '"学" 是汉字吗？',    method: 'is_hanzi?', args: ['学'],  expected: true },
  { subject: '语文', q: '"我爱学习" 几个字？', method: 'hanzi_count', args: ['我爱学习'], expected: 4 },
  { subject: '语文', q: '"快下雨了吗？" 什么句？', method: 'sentence_type', args: ['快下雨了吗？'], expected: '疑问' }
]

puts "老师：发卷 —— 小学综合卷（数学×4 ＋ 语文×4），满分 #{PAPER.size * 10} 分\n\n"

score = 0
PAPER.each_with_index do |item, i|
  result = agent.invoke_tool('verify', {
                               'plugin' => 'ra',
                               'method' => item[:method],
                               'cases' => [{ 'args' => item[:args], 'expected' => item[:expected] }]
                             })
  ok = result.start_with?('验证通过')
  score += 10 if ok
  actual = result[/实际=([^\s]+)/, 1] || item[:expected]
  puts format("  %d. [%s] %-22s → %s  %s", i + 1, item[:subject], item[:q],
              ok ? '答对' : "答错（正确答案 #{item[:expected]}）", ok ? '√' : "✗ 实际 #{actual}")
end

grade = case score
        when 80 then '优秀'
        when 60..79 then '良好'
        when 40..59 then '及格'
        else '待补课'
        end

puts "\n老师：收卷 —— ra 得分 #{score}/#{PAPER.size * 10}　（#{grade}）"
exit(score == PAPER.size * 10 ? 0 : 1)