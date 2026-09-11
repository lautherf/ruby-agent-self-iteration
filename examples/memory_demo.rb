# frozen_string_literal: true

# 记忆 = 结构化数据文件 + 简单读写；代码只当本体论（Memory::SCHEMA）+ 原子落盘。
# 运行：ruby -Ilib examples/memory_demo.rb

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

Dir.mktmpdir('memdemo') do |dir|
  path = File.join(dir, 'memory.yaml')
  memory = RubyAgent::Memory.new(path)

  # —— 1. 几条对话（who/what/kind/tags/when）——
  memory.add_turn(who: 'user', note: '帮我把小学数学内化进你自己', kind: 'task',  tags: ['math'])
  memory.add_turn(who: 'ra',   note: '我用 apply_code 新增了 add/sub/mul/div 并全部验证通过', kind: 'event', tags: ['math'])
  memory.add_turn(who: 'user', note: '聊点别的：你对自己有什么看法',         kind: 'fact',  tags: ['meta'])
  memory.add_turn(who: 'ra',   note: '我认为自己是一个会反思、可回滚、越迭代越稳的智能体', kind: 'meta', tags: ['meta'])
  memory.add_turn(who: 'user', note: '记得之后把旧的闲谈压缩掉',             kind: 'preference', tags: ['housekeeping'])

  puts "== 1. 刚聊完的 memory.yaml —— 纯结构化数据，简单读写：\n"
  puts File.read(path)
  puts "\n== 2. recall 精准召回：query='数学' →"
  memory.recall(query: '数学', limit: 10).each { |t| puts "   #{t[:id]}[#{t[:kind]}] #{t[:note]}" }

  # —— 3. 遗忘 = 重构：把窗口外的旧对话折叠成一条 lesson ——
  memory.consolidate!(keep: 2) { |batch| "压缩了 #{batch.size} 条 #{batch.flat_map { |t| t[:tags] }.uniq.join('+')} 话题对话" }
  puts "\n== 3. 折叠后的 memory.yaml —— 旧对话被删，只留最近 2 条 + 1 条压缩经验：\n"
  puts File.read(path)
  puts "== 结果: turns=#{memory.turns.size} lessons=#{memory.lessons.size} 可读/YAML合法=#{YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false)&.is_a?(Hash)}"
end
