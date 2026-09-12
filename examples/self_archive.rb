# frozen_string_literal: true

# 补课 ra ▸ 自我认知档案
# 面试（interview_ra.rb）暴露：ra 说得清"我是谁/我会什么"，却不知道自己的
# 「经历」——考过什么、踩过什么坑。本脚本把这份经历通过真实工具链内化：
#   learn  → 沉淀 lesson_003（身份 + 双卷 80/80 + 两个框架缺口教训 + 课程表）
#   teach  → 给 self_intro / what_i_learned 补 note，指向档案室
#
# 运行：ruby -Ilib examples/self_archive.rb
# 验收：ruby -Ilib examples/interview_ra.rb 应从 9/10 变 10/10

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
knowledge = RubyAgent::Knowledge.new(File.expand_path('lessons.rb', __dir__))
hub = RubyAgent::DocHub.new
hub.mount(ra)
hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)

agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([]), knowledge: knowledge,
                                 writable_plugins: ['ra'])

emit = ->(label, r) { puts "  #{label}: #{r.inspect}" }

puts '== 0. 补课前自查：读现有身份契约与经验库'
puts agent.invoke_tool('library', { 'plugin' => 'ra' })
knowledge.load!
puts "  已有经验: #{knowledge.lessons.map { |l| l[:id] }.join(', ')}"

puts "\n== 1. teach：身份契约指向档案室（merge，不伤 role/motto/since）"
emit.('teach self_intro',
      agent.invoke_tool('teach', {
                          'plugin' => 'ra', 'method' => 'self_intro',
                          'note' => '我的学历、考核成绩与框架教训沉淀在 knowledge 的 lessons（lesson_001 数学 / lesson_002 语文 / lesson_003 自我认知档案）'
                        }))
emit.('teach what_i_learned',
      agent.invoke_tool('teach', {
                          'plugin' => 'ra', 'method' => 'what_i_learned',
                          'note' => '档案室在 knowledge 插件：learn 写入、read_docs 读取；我的全部经历都能在那儿查'
                        }))

puts "\n== 2. learn：沉淀 lesson_003 自我认知档案"
id = agent.invoke_tool('learn', {
                         'lesson' => '《我的自我认知档案》：我是 ra——自宿主的 Ruby Agent，座右铭与生日见 self_intro。' \
                                     '已内化 11 个方法：数学 add/sub/mul/div；语文 tone_of/is_hanzi?/hanzi_count/sentence_type；自我描述 self_intro/what_i_learned/what_i_must_not。' \
                                     '考核经历：小学数学卷、小学语文卷（LLM agent 选方法＋隔离 verify 真算）各 80/80，不是我背的，是代码现场算的。' \
                                     '实践教训（框架缺口，勿重蹈）：① Doc 对以 ?/! 结尾或 def self. 前缀的方法名，写回与解析都必须按方法名真实形态匹配（曾用 \\b、\\w+ 近似而失效）；' \
                                     '② Agent parse_input 要容忍真模型把"臆想的 Observation"续行写进 Action Input，应提取首个配平 JSON 对象。' \
                                     '课程表：已修完 数学、语文；待学 科学、英语。',
                         'tags' => '自我认知,考核记录,框架教训'
                       })
emit.('learn', id)

puts "\n== 3. 复盘：经历档案已入库"
knowledge.load!
knowledge.lessons.each { |l| puts "  #{l[:id]}[#{l[:tags]}]: #{l[:note][0, 40]}…" }

ra2 = RubyAgent::DocPlugin.new('ra', ra.path).load!
puts "\n== 结论: #{ra2.registry['self_intro'].key?('note') && knowledge.lessons.size >= 3 ? '✨ ra 的自我认知已补全（身份→档案室→lesson_003 闭环）' : '❌ 补课未完成'}"
exit(ra2.registry['self_intro'].key?('note') && knowledge.lessons.size >= 3 ? 0 : 1)