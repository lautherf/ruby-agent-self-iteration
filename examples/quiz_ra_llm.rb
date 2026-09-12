# frozen_string_literal: true

# 出题 · LLM agent 判题 · 解
# 与 quiz_ra.rb 的差异：判卷（读题→选方法）这"第二条腿"交给真 LLM agent 做——
#   真模型读题 → library 自查方法库 → 用 verify 调 ra 内化的方法真算 → 得出答案。
# ra 只保证"方法运算真"（隔离子进程），模型只负责"这题该用哪个方法"。
#
# 用法：AGNES_API_KEY=sk-xxx ruby -Ilib examples/quiz_ra_llm.rb
#
# 判分：脚本监听每个 verify 事件，把模型自选的 插件#方法 与参考答案比对。

require 'fileutils'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model    = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
key      = ENV['AGNES_API_KEY'] or abort '缺少 AGNES_API_KEY（题目已出，模型判题版需要真 key 才能跑）'

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
hub = RubyAgent::DocHub.new
hub.mount(ra)

llm = RubyAgent::DeepSeekAdapter.new(base_url: base_url, api_key: key, model: model)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, max_steps: 40, writable_plugins: ['ra'])
agent.on(:llm_response) { |e| puts "\n── 模型 (step #{e[:index]}):\n#{e[:content]}" }
agent.on(:tool_call)    { |e| puts "→ #{e[:tool]} #{e[:input]}" }
agent.on(:verify) do |e|
  puts "  判题: #{e[:ok] ? '√' : '✗'} verify #{e[:plugin]}##{e[:method]} #{e[:ok] ? '' : "期望=#{e[:expected]} 实际=#{e[:actual]}"}"
end

PAPER = [
  { q: '3 + 5 = ?',       method: 'add',           expected: 8   },
  { q: '9 - 4 = ?',       method: 'sub',           expected: 5   },
  { q: '6 × 7 = ?',       method: 'mul',           expected: 42  },
  { q: '10 ÷ 4 = ?',      method: 'div',           expected: 2.5 },
  { q: '"shēng" 是几声？',  method: 'tone_of',       expected: 1   },
  { q: '"学" 是汉字吗？',    method: 'is_hanzi?',     expected: true },
  { q: '"我爱学习" 几个字？', method: 'hanzi_count',   expected: 4   },
  { q: '"快下雨了吗？" 什么句？', method: 'sentence_type', expected: '疑问' }
]

task = <<~TASK
  你是 ra 学生。老师发了一张口算卷，共 #{PAPER.size} 题，请逐题作答。

  【规则】
  1. 绝对不要心算。每道题都必须调用 verify 工具作答——在 verify 里填入你判断出的方法名和参数。
  2. 先用 library 查询你会哪些方法（方法名与实际能力要一一对上）。
  3. 一次只做一题，看到 Observation 再做下一题。
  4. 全部做完后，用 Final Answer 逐题报出你的答案和所用的方法名。

  【试卷】
  Q1. 3 + 5 = ?
  Q2. 9 - 4 = ?
  Q3. 6 × 7 = ?
  Q4. 10 ÷ 4 = ?
  Q5. "shēng" 是几声？（答案填 1/2/3/4）
  Q6. "学" 是汉字吗？（答案填 true/false）
  Q7. "我爱学习" 里汉字有几个？（答案填数字）
  Q8. "快下雨了吗？" 是什么句？（答案填 疑问/感叹/陈述）
TASK

puts "== 发卷（LLM agent 判题版）=="
agent.run(task)

puts "\n== 模型自选方法 vs 参考答案（判分）=="
uses = agent.events.select { |e| e[:type] == :verify && e[:ok] }
score = 0
PAPER.each_with_index do |item, i|
  chosen = uses.find { |e| e[:method] == item[:method] }
  hit = chosen && (chosen[:cases] || chosen.key?(:cases))
  correct = uses.any? { |e| e[:method] == item[:method] && e[:ok] }
  verdict = if correct
              score += 10
              "√ #{item[:method]} 判对（数字都由隔离进程真算）"
            else
              "✗ 未用 #{item[:method]} 作答"
            end
  puts format("  Q%d. %-12s → %s", i + 1, item[:q], verdict)
end
puts "\n== 结果: #{score}/#{PAPER.size * 10}（模型选方法＋ra 方法真算）=="