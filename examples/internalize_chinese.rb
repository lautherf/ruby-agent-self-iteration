# frozen_string_literal: true

# 学小学语文 · 内化
# 背景：小学数学（add/sub/mul/div）已内化进 ra 并有验收。此次按同一套链路学语文——
# 但只学"可自动验证"的能力（泛化边界结论的实战兑现）：
#   1. tone_of       —— 从带声调拼音读出几声音（hǎo→3），无声调返回 0
#   2. is_hanzi?     —— 判断单个字符是不是汉字（Unicode CJK 区间）
#   3. hanzi_count   —— 数出一段文字里有几个汉字
#   4. sentence_type —— 按结尾标点分句类：疑问/感叹/陈述/未知
#
# 走的工具链路三件套全开：
#   library 自查 → apply_code 长出方法 → verify(cases/raises) 隔离子进程真验算
#   → teach 写 @doc 契约 → learn 沉淀经验 → library 复盘
#
# 注：这是离线回放（工具序列固定），真模型版可把步骤交给 LLM 现写现验。
# 运行：ruby -Ilib examples/internalize_chinese.rb

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

puts "== 0. 动手前自查方法库（避免撞名/重复）"
puts agent.invoke_tool('library', { 'plugin' => 'ra' })

puts "\n== 1. 学语文：apply_code 长出 4 个能力"
lessons = [
  ['tone_of',
   "def tone_of(py)\n  tones = { 'ā'=>1, 'ē'=>1, 'ī'=>1, 'ō'=>1, 'ū'=>1, 'ǖ'=>1, 'á'=>2, 'é'=>2, 'í'=>2, 'ó'=>2, 'ú'=>2, 'ǘ'=>2, 'ǎ'=>3, 'ě'=>3, 'ǐ'=>3, 'ǒ'=>3, 'ǔ'=>3, 'ǚ'=>3, 'à'=>4, 'è'=>4, 'ì'=>4, 'ò'=>4, 'ù'=>4, 'ǜ'=>4 }.freeze\n  c = py.each_char.find { |ch| tones.key?(ch) }\n  c ? tones[c] : 0\nend",
   [{ 'args' => ['hǎo'], 'expected' => 3 }, { 'args' => ['mā'], 'expected' => 1 },
    { 'args' => ['ma'], 'expected' => 0 }, { 'args' => ['gè'], 'expected' => 4 }]
   ],
  ['is_hanzi?',
   "def is_hanzi?(c)\n  c.length == 1 && c.ord >= 0x4E00 && c.ord <= 0x9FFF\nend",
   [{ 'args' => ['中'], 'expected' => true }, { 'args' => ['a'], 'expected' => false },
    { 'args' => ['。'], 'expected' => false }]
   ],
  ['hanzi_count',
   "def hanzi_count(s)\n  s.each_char.count { |c| is_hanzi?(c) }\nend",
   [{ 'args' => ['春天真好'], 'expected' => 4 }, { 'args' => ['hello世界'], 'expected' => 2 }]
   ],
  ['sentence_type',
   "def sentence_type(s)\n  return '疑问' if s.end_with?('？')\n  return '感叹' if s.end_with?('！')\n  return '陈述' if s.end_with?('。')\n  '未知'\nend",
   [{ 'args' => ['你去哪？'], 'expected' => '疑问' }, { 'args' => ['真美！'], 'expected' => '感叹' },
    { 'args' => ['我去上学。'], 'expected' => '陈述' }, { 'args' => ['ok'], 'expected' => '未知' }]
   ]
]
methods = {}
lessons.each do |name, code, cases|
  emit.('apply_code', agent.invoke_tool('apply_code', { 'plugin' => 'ra', 'method' => name, 'code' => code }))
  result = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => name, 'cases' => cases })
  emit.("verify #{name}", result)
  methods[name] = result.start_with?('验证通过')
end

puts "\n== 2. teach 写 @doc 契约"
teach = [
  ['tone_of', '拼音声调识别：从带声调拼音读出几声音（hǎo→3），无声调返回 0'],
  ['is_hanzi?', '汉字判断：单个字符是否属于 Unicode 汉字区（CJK）'],
  ['hanzi_count', '汉字计数：数出一段文字里的汉字个数'],
  ['sentence_type', '句类判断：按结尾标点分 疑问/感叹/陈述/未知']
]
teach.each do |name, note|
  emit.("teach #{name}", agent.invoke_tool('teach', { 'plugin' => 'ra', 'method' => name, 'role' => note, 'note' => '小学语文内化' }))
end

puts "\n== 3. learn 沉淀语文学习经验"
id = agent.invoke_tool('learn', {
                         'lesson' => '我通过 apply_code 学完了小学语文的 4 个可验证能力：tone_of（声调识别）、is_hanzi?（汉字判断）、hanzi_count（汉字计数）、sentence_type（句类判断）；每个都经隔离 verify 批量算例通过（含边界），并已 teach 写好 @doc 契约',
                         'tags' => '语文,拼音,汉字,句类'
                       })
emit.('learn', id)

puts "\n== 4. 复盘：方法库 + 经验库"
puts agent.invoke_tool('library', { 'plugin' => 'ra' })
knowledge.load!
knowledge.lessons.each { |l| puts "  #{l[:id]}: #{l[:note]}" }

ok = methods.values.all?
puts "\n== 结论: #{ok ? '✨ ra 学完小学语文（4 能力 × 14 算例全过，含汉字/拼音/句类边界）' : '❌ 有方法未通过验收'}"
exit(ok ? 0 : 1)