# frozen_string_literal: true

require 'fileutils'
require_relative 'agent_loop'
require_relative 'knowledge'

module RubyAgent
  # IterationLoop —— 迭代闭环编排（Sprint 5 闭环验证）。
  #
  # 闭环 = 成功标准 #5「把这次经验写回知识库」+ #6「下一次迭代从更新后的知识出发」：
  #
  #   task → AgentLoop(fresh) → 任务完成 → reflect 出经验 → Knowledge 沉淀
  #        → 下一轮 Agent 的 system prompt 已包含上一轮知识（经 DocHub for_llm）
  #
  # 职责分离：AgentLoop 只负责"执行一个任务"；IterationLoop 负责"多轮执行 + 沉淀 + 反馈"。
  class IterationLoop
    # 单轮结果快照
    Result = Struct.new(:index, :task, :answer, :status, keyword_init: true)

    # 缺省 reflect：取 Agent 自己通过 learn 工具沉淀的经验（state.learned）
    DEFAULT_REFLECT = lambda { |state|
      Array(state.respond_to?(:learned) ? state.learned : [])
    }

    attr_reader :hub, :knowledge, :results, :agents

    # builder: 无参可调用，返回一个绑定好 hub/llm/knowledge 的全新 AgentLoop
    # reflect: 可调用(agent.state) -> [{ lesson:, tags:, }]；缺省用 Agent 自学的经验
    def initialize(hub:, builder:, knowledge:, reflect: DEFAULT_REFLECT)
      @hub = hub
      @builder = builder
      @knowledge = knowledge
      @reflect = reflect || DEFAULT_REFLECT
      @results = []
      @agents = []
      mount_knowledge
    end

    # 顺序执行多个任务；每轮结束沉淀经验，下一轮自动读到上一轮知识。
    def run(tasks)
      Array(tasks).each_with_index do |task, index|
        agent = @builder.call
        agent.run(task)
        @agents << agent

        sediment(agent.state)
        reload_knowledge_plugin

        @results << Result.new(
          index: index, task: task,
          answer: agent.state.answer,
          status: agent.state.status
        )
      end
      @results
    end

    private

    # 把 Knowledge 挂到 DocHub，使知识进入 for_llm（已存在则跳过）。
    # 首次运行时先落空文件，避免 DocPlugin.load! 对不存在的文件发「加载失败」告警。
    def mount_knowledge
      return if @hub.get(Knowledge::NAME)

      FileUtils.mkdir_p(File.dirname(@knowledge.path)) unless File.directory?(File.dirname(@knowledge.path))
      File.write(@knowledge.path, Knowledge::DEFAULT_HEADER) unless File.exist?(@knowledge.path)
      @hub.mount(DocPlugin.new(Knowledge::NAME, @knowledge.path).load!)
    end

    def sediment(state)
      Array(@reflect.call(state)).each do |item|
        next unless item && !item[:lesson].to_s.strip.empty?

        @knowledge.add(item[:lesson], tags: item[:tags])
      end
    end

    def reload_knowledge_plugin
      @hub.get(Knowledge::NAME)&.load!
    end
  end
end