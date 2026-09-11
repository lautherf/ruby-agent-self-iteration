# frozen_string_literal: true

# 让 ra 把小学数学内化进自己：ra 用 apply_code 在自己的插件文件 plugins/ra.rb 里
# 新增四则运算方法，用 verify 验证、teach 写好注释契约、learn 沉淀经验。
# 本脚本只负责搭台与提问 —— 每一行数学代码都由 ra 自己写，全程不加指导。
#
# 用法：
#   AGNES_API_KEY=sk-xxx ruby -Ilib examples/internalize_math.rb
#
# 内化物落点：plugins/ra.rb（真实仓库文件，可 commit）与 examples/lessons.rb。

require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model    = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
key      = ENV['AGNES_API_KEY'] or abort <<~USAGE
  缺少 AGNES_API_KEY。请通过环境变量传入，例如：
  AGNES_API_KEY=sk-... ruby -Ilib examples/internalize_math.rb
USAGE

ra_path = File.expand_path('../plugins/ra.rb', __dir__)
puts "== ra 的插件文件: #{ra_path}"

hub = RubyAgent::DocHub.new
RubyAgent.mount_ra!(hub)  # ra 编辑的就是它自己的身份契约文件
knowledge = RubyAgent::Knowledge.new(File.join(__dir__, 'lessons.rb'))

llm = RubyAgent::DeepSeekAdapter.new(base_url: base_url, api_key: key, model: model)
puts "== 模型: #{llm.inspect}"

agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, max_steps: 30, knowledge: knowledge)
agent.on(:llm_response) { |e| puts "\n── 模型回复 (#{e[:index]}):\n#{e[:content]}" }
agent.on(:tool_call)    { |e| puts "→ 调用工具: #{e[:tool]} #{e[:input]}" }
agent.on(:observation)  { |e| puts "  观察: #{e[:observation]}" }
agent.on(:code_change)  { |e| puts "  ★ code_change: #{e[:method]} #{e[:status]}" }
agent.on(:verify)       { |e| puts "  ★ verify: ok=#{e[:ok]} actual=#{e[:actual]} expected=#{e[:expected]} rolled_back=#{e[:rolled_back]}" }
agent.on(:rollback)     { |e| puts "  ★ rollback: #{e[:method]}" }
agent.on(:learn)        { |e| puts "  ★ learn: #{e[:id]} #{e[:lesson]}" }

task = <<~TASK
  把小学数学内化进你自己。
  你的插件文件 plugins/ra.rb 就是你自己：请在其中实现小学数学的四则运算（加法、减法、乘法、除法）。
  用 apply_code 新增方法实现它们（方法不存在时 apply_code 会自动追加到文件末尾），
  每个方法都要用 verify 以若干个真实算例验证正确性（除法请确保你的实现能处理除数为 0 的边界），
  用 teach 为每个方法写好 @doc 注释契约（role / note），
  最后用 learn 把你这次学到的经验沉淀下来。
  方法命名与实现细节完全由你决定。全部完成后，用 Final Answer 介绍你新增了哪些能力、验证结果如何。
  重要：严格按 ReAct 格式，**每一条回复只输出一个 Action 和一个 Action Input**，
  不要用 --- 分隔多个 Action，也不要一口气写很多动作 —— 一次一步，看 Observation 再走下一步。
TASK

answer = agent.run(task)
puts "\n== Final Answer: #{answer.inspect}"

puts "\n== 审计轨迹:"
agent.state.code_changes.each { |c| puts "  #{c[:plugin]}##{c[:method]} → #{c[:status]}" }

puts "\n== 沉淀经验:"
knowledge.load!
knowledge.lessons.each { |l| puts "  #{l[:id]}: #{l[:note]}" }
puts "\n== 结果: status=#{agent.state.status} 新增方法=#{agent.state.code_changes.count { |c| c[:status] == :verified }} 个已验证"