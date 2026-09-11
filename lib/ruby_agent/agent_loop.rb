# frozen_string_literal: true

require 'json'
require_relative 'llm_adapter'

module RubyAgent
  # AgentLoop —— ReAct 循环：Thought → Action → Observation → … → Final Answer。
  #
  # 依赖注入：hub（DocHub，提供知识读写）+ llm（LLMAdapter，提供模型调用）。
  # 事件驱动：所有关键节点通过 #on 回调广播，并记录在 #events 里。
  class AgentLoop
    # 请求了未注册的工具
    class UnknownToolError < StandardError; end

    Step = Struct.new(:index, :thought, :raw, :action, :action_input, :observation, keyword_init: true)

    THOUGHT_RE      = /^Thought:\s*(.*)$/
    ACTION_RE       = /^Action:\s*(.*)$/
    ACTION_INPUT_RE = /^Action Input:\s*(.*)$/
    FINAL_RE        = /^Final Answer:\s*(.*)\z/m

    DEFAULT_SYSTEM_PROMPT = <<~PROMPT
      你是一个可以调用工具的智能体，请严格按 ReAct 格式作答：
      Thought: 你的思考
      Action: 工具名
      Action Input: JSON 格式的参数
      当你已经可以给出最终答案时，改为：
      Final Answer: 你的答案
    PROMPT

    # 运行状态快照
    class State
      attr_accessor :task, :plugins, :steps, :answer, :error, :status

      def initialize
        @task = nil
        @plugins = []
        @steps = []
        @answer = nil
        @error = nil
        @status = :idle
      end

      def finished?
        %i[done max_steps error].include?(@status)
      end
    end

    attr_reader :hub, :llm, :state, :events, :tools

    def initialize(hub:, llm:, max_steps: 8, system_prompt: DEFAULT_SYSTEM_PROMPT)
      @hub = hub
      @llm = llm
      @max_steps = max_steps
      @system_prompt = system_prompt
      @tools = {}
      @events = []
      @observers = []
      @state = State.new
      register_default_tools
    end

    # 注册工具：name => 接收解析后 input 的 block
    def register_tool(name, &block)
      @tools[name.to_s] = block
      self
    end

    # 订阅事件；type 为 nil 时接收全部事件
    def on(type = nil, &block)
      @observers << [type, block]
      self
    end

    # 主循环：跑任务，返回最终答案（未收敛时返回 nil）
    def run(task)
      reset_state(task)
      emit(:start, task: task)
      refresh_state!

      index = 0
      while index < @max_steps
        begin
          response = @llm.chat(build_messages(task))
        rescue LLMAdapter::Error => e
          @state.status = :error
          @state.error = "#{e.class}: #{e.message}"
          emit(:error, error: @state.error)
          return nil
        end

        emit(:llm_response, content: response, index: index)
        parsed = parse_response(response)

        if parsed[:type] == :final
          @state.answer = parsed[:answer]
          @state.status = :done
          emit(:finish, answer: @state.answer)
          return @state.answer
        end

        step = Step.new(index: index, thought: parsed[:thought], raw: response,
                        action: parsed[:action], action_input: parsed[:action_input])
        emit(:tool_call, tool: step.action, input: step.action_input, index: index)

        outcome = execute_tool(step.action, step.action_input)
        step.observation = outcome[:ok] ? outcome[:value].to_s : "ERROR: #{outcome[:error]}"
        @state.steps << step
        emit(:observation, tool: step.action, ok: outcome[:ok], observation: step.observation, index: index)

        index += 1
      end

      @state.status = :max_steps
      @state.error = "达到最大步数 #{@max_steps} 仍未给出 Final Answer"
      emit(:max_steps, error: @state.error)
      nil
    end

    # 直接调用工具（raw 返回值）；未注册时抛 UnknownToolError
    def invoke_tool(name, input)
      tool = @tools[name.to_s]
      raise UnknownToolError, "未知工具: #{name}" if tool.nil?

      tool.call(input)
    end

    # 从 DocHub 重新读取插件清单（只同步名单，不动内容）
    def refresh_state!
      @state.plugins = @hub.plugins.keys.map(&:to_s)
    end

    # 状态同步 + 热重载：重读插件文件，使磁盘上的改动生效
    def sync!
      names = @hub.plugins.keys.map(&:to_s)
      names.each { |name| @hub[name]&.load! }
      @state.plugins = names
      emit(:synced, plugins: names)
      names
    end

    private

    def reset_state(task)
      @state = State.new
      @state.task = task
      @state.status = :running
    end

    def build_messages(task)
      messages = []
      system = system_content
      messages << { role: 'system', content: system } unless system.empty?
      messages << { role: 'user', content: task }
      @state.steps.each do |step|
        messages << { role: 'assistant', content: step.raw }
        messages << { role: 'user', content: "Observation: #{step.observation}" }
      end
      messages
    end

    def system_content
      parts = [@system_prompt]
      docs = @hub.for_llm
      unless docs.empty?
        parts << "可用文档插件：\n#{docs.map { |doc| format_doc(doc) }.join("\n")}"
      end
      parts.join("\n\n")
    end

    def format_doc(doc)
      methods = (doc[:methods] || {}).map do |name, spec|
        detail = spec.is_a?(Hash) ? spec.map { |k, v| "#{k}=#{v}" }.join(', ') : spec.to_s
        "#{name}(#{detail})"
      end
      "- #{doc[:plugin]}: #{methods.join('; ')}"
    end

    def parse_response(text)
      text = text.to_s
      if (m = text.match(FINAL_RE))
        return { type: :final, answer: m[1].strip }
      end

      action = text[ACTION_RE, 1]&.strip
      # 没写 Action 的普通回复，直接视为最终答案，避免空转
      return { type: :final, answer: text.strip } if action.nil?

      {
        type: :action,
        thought: text[THOUGHT_RE, 1]&.strip,
        action: action,
        action_input: parse_input(text[ACTION_INPUT_RE, 1]&.strip)
      }
    end

    def parse_input(raw)
      return {} if raw.nil? || raw.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : { 'value' => parsed }
    rescue JSON::ParserError
      { 'value' => raw }
    end

    def execute_tool(name, input)
      { ok: true, value: invoke_tool(name, input) }
    rescue StandardError => e
      { ok: false, error: "#{e.class}: #{e.message}" }
    end

    def register_default_tools
      register_tool('list_docs') { |_input| @hub.for_llm }
      register_tool('read_docs') { |_input| @hub.for_llm }
      register_tool('teach') do |input|
        input = {} if input.nil?
        plugin = input['plugin'] || input[:plugin]
        method = input['method'] || input[:method]
        spec = input.reject { |k, _v| %w[plugin method].include?(k.to_s) }.transform_keys(&:to_sym)
        @hub.teach(plugin, method, **spec)
      end
    end

    def emit(type, payload = {})
      event = { type: type }.merge(payload)
      @events << event
      @observers.each do |(wanted, block)|
        next if wanted && wanted != type

        block.call(event)
      end
      event
    end
  end
end
