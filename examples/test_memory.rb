# frozen_string_literal: true

# 「记忆即代码」真模型端到端测试：
#   会话 A：ra 用 remember 把 3 件关于用户的事写进记忆
#   会话 B：全新 Agent（无对话上下文，只共享同一个 memory 文件）read_memory 回忆
# 若 B 答出这 3 件事 → 跨会话对话记忆成立。
#
# 用法：AGNES_API_KEY=sk-xxx ruby -Ilib examples/test_memory.rb

require 'fileutils'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model    = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
key      = ENV['AGNES_API_KEY'] or abort '缺少 AGNES_API_KEY'

dir = File.join(__dir__, 'memory_test')
FileUtils.rm_rf(dir)
FileUtils.mkdir_p(dir)
path = File.join(dir, 'memory.rb')

memory = RubyAgent::Memory.new(path)
hub = RubyAgent::DocHub.new
RubyAgent.mount_ra!(hub)
hub.mount(memory.plugin.load!)

def new_agent(hub, key, base_url, model, memory)
  llm = RubyAgent::DeepSeekAdapter.new(base_url: base_url, api_key: key, model: model)
  agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, memory: memory, max_steps: 12)
  agent.on(:llm_response) { |e| puts "\n── 回复 (#{e[:index]}):\n#{e[:content]}" }
  agent.on(:tool_call)    { |e| puts "→ 工具: #{e[:tool]} #{e[:input]}" }
  agent.on(:observation)  { |e| puts "  观察: #{e[:observation]}" }
  agent.on(:remember)     { |e| puts "  ★ 记住: #{e[:id]}[#{e[:who]}] #{e[:note]}" }
  agent
end

puts '======== 会话 A：把三件事写进记忆 ========'
agent_a = new_agent(hub, key, base_url, model, memory)
answer_a = agent_a.run(<<~TASK)
  请用 remember 工具把三件关于用户的事实写进记忆（每条一条 remember）：
  1) 项目名是 weixin
  2) 用户喜欢蓝色
  3) 用户的口头禅是"稳字当头"
  注意：每一条回复只输出一个 Action，一次一步，看到 Observation 再继续。
  全部写完用 Final Answer 确认。
TASK
puts "\n【会话 A 答复】#{answer_a}"

puts "\n======== 记忆文件（记忆即代码）========\n"
puts File.read(path)

puts "\n======== 会话 B：全新 Agent，无对话上下文，只能靠 read_memory ========"
memory.plugin.load!  # 让 B 读到 A 写下的记忆
agent_b = new_agent(hub, key, base_url, model, memory)
answer_b = agent_b.run(<<~TASK)
  这是新的对话，你没有刚才的对话上下文。请先调用 read_memory 查你的记忆，
  然后回答三个问题：项目叫什么？用户喜欢什么颜色？用户的口头禅是什么？
  用 Final Answer 逐条回答。
TASK
puts "\n【会话 B 答复】#{answer_b}"

checks = %w[weixin 蓝色 稳字当头]
missed = checks.reject { |w| answer_b.to_s.include?(w) }
puts "\n======== 判定 ========"
puts "  命中: #{checks.map { |w| "#{w}=#{answer_b.to_s.include?(w)}" }.join(' ')}"
puts "  跨会话记忆: #{missed.empty? ? '✅ 成立' : "❌ 缺 #{missed.join(' / ')}"}"
FileUtils.rm_rf(dir)