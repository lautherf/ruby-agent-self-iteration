# frozen_string_literal: true

# 让 ra 用真实模型回答：你是谁，你知道自己什么信息。
#
# 用法：
#   AGNES_API_KEY=sk-xxx ruby -Ilib examples/ask_ra.rb
#   AGNES_MODEL=agnes-2.5-flash AGNES_BASE_URL=https://apihub.agnes-ai.com/v1 可覆盖默认
#
# ra 的一切自我认识都来自 plugins/ra.rb 这份「身份契约」，
# 和它认识任何插件共用同一套 `# @doc` 机制 —— 一切皆插件，ra 自己也是插件。

require_relative '../lib/ruby_agent'

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model    = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
key      = ENV['AGNES_API_KEY'] or abort <<~USAGE
  缺少 AGNES_API_KEY。请通过环境变量传入，例如：
  AGNES_API_KEY=sk-... ruby -Ilib examples/ask_ra.rb
USAGE

hub = RubyAgent::DocHub.new
RubyAgent.mount_ra!(hub)  # ra 认识自己：挂载身份契约
knowledge = RubyAgent::Knowledge.new(File.join(__dir__, 'lessons.rb'))

agent = RubyAgent::AgentLoop.new(
  hub: hub,
  llm: RubyAgent::DeepSeekAdapter.new(
    base_url: base_url,
    api_key:  key,
    model:    model
  ),
  knowledge: knowledge  # ra 能读到"我学过什么"：经验沉淀
)
agent.on(:llm_response) { |e| Kernel.puts "\n── 模型回复:\n#{e[:content]}" }
agent.on(:tool_call)    { |e| Kernel.puts "→ 调用工具: #{e[:tool]} #{e[:input]}" }
agent.on(:observation)  { |e| Kernel.puts "  观察: #{e[:observation]}" }

question = ARGV[0] || <<~ASK
  你是谁？你能说出关于你自己的哪些信息？请先调用 whoami（或 list_docs 看 ra 插件），
  再基于你读到的身份契约，用 Final Answer 做一段自我介绍。
ASK

answer = agent.run(question)
Kernel.puts "\n== ra 的自我介绍:\n#{answer}"