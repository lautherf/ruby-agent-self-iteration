# frozen_string_literal: true

# 「记忆即代码」离线演示：对话记忆不是数据库行，而是一段 Ruby 代码。
# 运行：ruby -Ilib examples/memory_demo.rb

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

Dir.mktmpdir('memdemo') do |dir|
  path = File.join(dir, 'memory.rb')
  memory = RubyAgent::Memory.new(path)

  # —— 1. 几条对话（谁说的 / 说了啥 / 什么时候 / 话题标签）——
  memory.add_turn(who: 'user', note: '帮我把小学数学内化进你自己', tags: 'math')
  memory.add_turn(who: 'ra',   note: '我用 apply_code 新增了 add/sub/mul/div 并全部验证通过', tags: 'math')
  memory.add_turn(who: 'user', note: '聊点别的：你对自己有什么看法', tags: 'meta')
  memory.add_turn(who: 'ra',   note: '我认为自己是一个会反思、可回滚、越迭代越稳的智能体', tags: 'meta')
  memory.add_turn(who: 'user', note: '记得之后把旧的闲谈压缩掉', tags: 'housekeeping')

  puts "== 1. 刚聊完的 memory.rb —— 记忆 = 可编译的 Ruby 文件：\n"
  puts File.read(path)
  puts "\n== 2. recall 精准召回：query='数学' →"
  memory.recall(query: '数学', limit: 10).each { |t| puts "   #{t[:id]}[#{t[:who]}] #{t[:note]}" }

  # —— 3. 遗忘 = 重构：把窗口外的旧对话折叠成一条 lesson ——
  memory.consolidate!(keep: 2) { |batch| "压缩了 #{batch.size} 条 #{batch.map { |t| t[:tags] }.uniq.join('+')} 话题对话" }
  puts "\n== 3. 折叠后的 memory.rb —— 旧对话被删，只留最近 2 条 + 1 条压缩经验：\n"
  puts File.read(path)
  puts "== 结果: turns=#{memory.turns.size} lessons=#{memory.lessons.size} 可编译=#{!!RubyVM::InstructionSequence.compile(File.read(path))}"
end