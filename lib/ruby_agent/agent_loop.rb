# frozen_string_literal: true

require 'json'
require_relative 'llm_adapter'
require_relative 'code_editor'
require_relative 'memory'

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

    # 真实模型（如 Agnes）常因"自认无工具"而拒绝执行；
    # 注入明确的工具清单 + 调用约定，能显著提高遵循率。
    TOOL_HINTS = {
      'list_docs' => '查看全部插件的 @doc 知识（含记忆 doc 视图与经验），参数：{}',
      'read_docs' => '查看全部插件的 @doc 知识（含记忆与经验），参数：{}',
      'whoami' => '向 ra 自己的身份契约提问：我是谁、我学过什么、我不能做什么，参数：{}',
      'read_code' => '读取某个方法的当前源码，参数：{"plugin":"插件名","method":"方法名"}',
      'apply_code' => '把方法体整体替换为新代码；方法不存在时自动新增（追加到文件末尾），参数：{"plugin":"插件名","method":"方法名","code":"def 方法名(...)\\n实现\\nend"}。要求 code 定义同名方法，语法错会自动拒绝。',
      'verify' => '在内存作用域真实运行方法并按验证项比对（可编程验证器：支持批量算例 cases=[{args,expected}]、异常边界 raises 期望抛错类名、布尔断言 assert 用表达式以 result 为输入，如 "result.odd?"）。参数：{"plugin":"插件名","method":"方法名","cases":[{"args":[..],"expected":期望值}]} 或单条 {"plugin":..,"method":..,"args":[..],"expected":..,"raises":..,"assert":..}。每项 args 必填，expected/raises/assert 三选一。任一验证项不过即失败，之前有 apply_code 时系统会自动回滚该修改。',
      'teach' => '写回插件方法的 @doc 元数据，参数：{"plugin":"插件名","method":"方法名","role":"..","note":".."}',
      'learn' => '把经验沉淀进知识仓库，参数：{"lesson":"经验文本","tags":"可选标签"}',
      'remember' => '把一条对话写进记忆（结构化数据，经本体论校验：kind/who/status 有受控取值，supersedes 必须指向真实存在的记录 id）。参数：{"kind":"fact|preference|task|event|meta，默认 fact","who":"user|ra|system|tool，默认 ra","note":"内容","status":"stated|confirmed，可选","about":"这条记忆关于谁，可选","supersedes":"被它取代的旧记录 id，可选（修订时用）","tags":"可选标签"}',
      'read_memory' => '按内容召回记忆中的对话，参数：{"query":"关键词，可空","limit":"条数，默认 5"}',
      'promote' => '把一条确证记忆内化成可执行方法（记忆运转）：@doc 溯源 memory id，记忆标 confirmed。参数：{"memory":"记忆 id","plugin":"目标插件，默认 ra","method":"方法名","code":"def 方法名(...)\\n实现\\nend"}'
    }.freeze

    # 运行状态快照
    class State
      attr_accessor :task, :plugins, :steps, :answer, :error, :status, :learned, :code_changes

      def initialize
        @task = nil
        @plugins = []
        @steps = []
        @answer = nil
        @error = nil
        @status = :idle
        @learned = []          # Sprint 5：Agent 通过 learn 工具沉淀的经验记录
        @code_changes = []     # Sprint 6：Agent 代码级自改的审计轨迹（applied/verified/rolled_back）
      end

      def finished?
        %i[done max_steps error].include?(@status)
      end
    end

    attr_reader :hub, :llm, :state, :events, :tools

    def initialize(hub:, llm:, max_steps: 8, system_prompt: DEFAULT_SYSTEM_PROMPT, knowledge: nil, memory: nil, auto_rollback: true)
      @hub = hub
      @llm = llm
      @max_steps = max_steps
      @system_prompt = system_prompt
      @knowledge = knowledge
      @memory = memory
      @auto_rollback = auto_rollback
      @tools = {}
      @events = []
      @observers = []
      @state = State.new
      @editors = {}
      @pending_change = nil
      register_default_tools
      register_learn_tool if @knowledge
      register_remember_memory_tools if @memory
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

        # 一条回复可能塞了多个 Action（真模型老毛病）：全部按序执行，最后认 Final。
        actions = parsed[:actions] || [{ action: parsed[:action], input: parsed[:action_input] }]
        actions.each do |a|
          step = Step.new(index: index, thought: parsed[:thought], raw: response,
                          action: a[:action], action_input: a[:input])
          emit(:tool_call, tool: step.action, input: step.action_input, index: index)

          outcome = execute_tool(step.action, step.action_input)
          step.observation = outcome[:ok] ? outcome[:value].to_s : "ERROR: #{outcome[:error]}"
          @state.steps << step
          emit(:observation, tool: step.action, ok: outcome[:ok], observation: step.observation, index: index)

          index += 1
          break if index >= @max_steps
        end

        if parsed[:final]
          @state.answer = parsed[:final]
          @state.status = :done
          emit(:finish, answer: @state.answer)
          return @state.answer
        end
      end

      @state.status = :max_steps
      @state.error = "达到最大步数 #{@max_steps} 仍未给出 Final Answer"
      emit(:max_steps, error: @state.error)
      nil
    ensure
      record_active_turn(task) if @memory
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
      @pending_change = nil   # 每次 run 独立，不留跨任务的悬空回滚
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
      tools = @tools.keys.sort.filter_map { |name| TOOL_HINTS[name] && "- #{name}: #{TOOL_HINTS[name]}" }
      unless tools.empty?
        parts << "可用工具（必须用 Action 指定工具名，Action Input 必须是 JSON）：\n#{tools.join("\n")}"
      end
      docs = @hub.for_llm
      unless docs.empty?
        parts << "可用文档插件：\n#{docs.map { |doc| format_doc(doc) }.join("\n")}"
      end
      if @memory
        mem = @memory.for_llm
        unless mem.empty?
          parts << "记忆（最近对话，可引用；全部记忆可经 read_docs 或 read_memory 主动查阅，记忆可 promote 成方法）:\n#{mem}"
        end
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
      # Action 优先于 Final：真实模型常把 Action + Final Answer 塞进同一条回复，
      # 若先匹配 Final 会让工具一个都没执行（测试抓到的坑）。
      # 更进一步：同一条回复里塞了 N 个 Action（真模型老毛病），全部照单执行，最后认 Final。
      actions = scan_actions(text)
      final = text.match(FINAL_RE)&.then { |m| m[1].strip }

      unless actions.empty?
        first = actions.first
        return {
          type: :action,
          thought: text[THOUGHT_RE, 1]&.strip,
          action: first[:action],        # 兼容形态：只暴露第一个
          action_input: first[:input],
          actions: actions,               # 主用：这条回复里的全部动作
          final: final
        }
      end

      return { type: :final, answer: final } if final && !final.empty?

      # 没写 Action 的普通回复，直接视为最终答案，避免空转
      { type: :final, answer: text.strip }
    end

    # 逐行扫描一条回复里出现的所有 Action 块（Action: X / Action Input: {...}），
    # Action Input 若跨行则续行收集，交给 parse_input 剥围栏。
    def scan_actions(text)
      actions = []
      lines = text.lines
      i = 0
      while i < lines.size
        if (m = lines[i].match(/\AAction:\s*(.+?)\s*\z/))
          name = m[1].strip
          if i + 1 < lines.size && (im = lines[i + 1].match(/\AAction Input:\s*(.*?)\s*\z/))
            raw = im[1].strip
            j = i + 2
            while j < lines.size && !lines[j].match?(/\A(?:Thought|Action|Action Input|Final Answer|Observation)\s*:/)
              raw << "\n" << lines[j].rstrip
              j += 1
            end
            actions << { action: name, input: parse_input(raw) }
            i = j
          else
            actions << { action: name, input: {} }
            i += 1
          end
        else
          i += 1
        end
      end
      actions
    end

    def parse_input(raw)
      return {} if raw.nil? || raw.empty?

      text = raw.to_s.strip
      text = text.sub(/\A```(?:json)?\s*/i, '').sub(/```\z/, '')   # 兼容推理模型输出 ```json 围栏
      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : { 'value' => parsed }
    rescue JSON::ParserError
      { 'value' => raw }
    end

    def execute_tool(name, input)
      { ok: true, value: invoke_tool(name, input) }
    rescue StandardError => e
      { ok: false, error: "#{e.class}: #{e.message}" }
    end

    # —— Sprint 6 代码工具辅助 ——

    def editor_name(input)
      input = {} if input.nil?
      name = (input['plugin'] || input[:plugin]).to_s
      raise ArgumentError, "插件缺失" if name.empty?
      raise ArgumentError, "插件不存在: #{name}" if @hub.get(name).nil?

      name
    end

    # 取插件路径对应的 CodeEditor（按路径缓存）
    def editor_for_plugin(input)
      name = editor_name(input)
      path = @hub.get(name).path
      (@editors[path] ||= CodeEditor.new(path))
    end

    # 验证通过：把对应该插件/方法的最近一次 applied 标记为 verified
    def mark_code_verified(plugin, method)
      record = @state.code_changes.reverse.find do |c|
        c[:plugin] == plugin && c[:method] == method && c[:status] == :applied
      end
      record[:status] = :verified if record
      record
    end

    # 回滚上一次代码变更（仅限同名插件的未决变更），返回是否执行了回滚
    def rollback_pending(plugin, method)
      pending = @pending_change
      return false unless pending && pending[:plugin] == plugin && pending[:method] == method

      if pending[:editor].rollback!
        record = pending.slice(:plugin, :method).merge(status: :rolled_back)
        @state.code_changes << record
        emit(:rollback, **record)
        @pending_change = nil
        true
      else
        false
      end
    end

    # apply_code 与 promote 共用的写方法路径：试编译 → 原子落盘 → 记入 code_changes。
    def perform_apply(input)
      method = (input['method'] || input[:method]).to_s
      code = input['code'] || input[:code] || input['source'] || ''
      editor = editor_for_plugin(input)
      ok = if editor.read_method(method).nil?
             editor.add(method, code)      # 不存在 → 追加新方法（自改长出能力）
           else
             editor.replace(method, code)  # 已存在 → 整体替换
           end
      raise "替换失败：语法错误或方法名不匹配 #{method}" unless ok

      @pending_change = { plugin: editor_name(input), method: method, editor: editor }
      record = { plugin: editor_name(input), method: method, status: :applied }
      @state.code_changes << record
      emit(:code_change, **record)
      record
    end

    def register_default_tools
      register_tool('list_docs') { |_input| @hub.for_llm }
      register_tool('read_docs') { |_input| @hub.for_llm }
      register_tool('whoami') do |_input|
        ra = @hub.get('ra')
        if ra
          identity = ra.registry.map do |name, spec|
            detail = spec.is_a?(Hash) ? spec.map { |k, v| "#{k}=#{v}" }.join('，') : spec.to_s
            "- #{name}: #{detail}"
          end.join("\n")
          "我是 #{RubyAgent::NAME}（v#{RubyAgent::VERSION}）。#{RubyAgent::MOTTO}\n身份契约：\n#{identity}"
        else
          "我是 #{RubyAgent::NAME}（#{RubyAgent::VERSION}）。#{RubyAgent::MOTTO}（身份契约未挂载，可用 RubyAgent.mount_ra!(hub) 让我认识自己）"
        end
      end
      register_tool('teach') do |input|
        input = {} if input.nil?
        plugin = input['plugin'] || input[:plugin]
        method = input['method'] || input[:method]
        spec = input.reject { |k, _v| %w[plugin method].include?(k.to_s) }.transform_keys(&:to_sym)
        @hub.teach(plugin, method, **spec)
      end
      register_code_tools
    end

    # Sprint 6：代码级自修改工具 —— read_code / apply_code / verify。
    #
    # 闭环语义：apply_code 应用新方法体（试编译+原子落盘）→ verify 用真实求值验证；
    # 验证失败且 auto_rollback 开启时，**自动回滚到上一版本**并把结果回灌给 LLM，
    # 让 Agent 基于"已自动回滚"的 observation 重试 —— 成功标准 #3 的代码层落地。
    def register_code_tools
      register_tool('read_code') do |input|
        method = (input['method'] || input[:method]).to_s
        editor_for_plugin(input).read_method(method) || "未找到方法 #{method}"
      end

      register_tool('apply_code') do |input|
        record = perform_apply(input || {})
        "已应用新实现到 #{record[:plugin]}##{record[:method]}"
      end

      register_tool('verify') do |input|
        input = {} if input.nil?
        method = (input['method'] || input[:method]).to_s
        editor = editor_for_plugin(input)
        scope = editor.scope
        obj = Object.new.extend(scope)

        cases = input['cases'] || input[:cases]
        forms = if cases
                  cases.map { |c| (c || {}).transform_keys(&:to_s) }
                else
                  [input.reject { |k, _v| %w[plugin method].include?(k.to_s) }.transform_keys(&:to_s)]
                end
        raise '缺少验证项：请提供 args+expected、args+raises、args+assert 或 cases 批量算例' if forms.empty?

        details = forms.map { |form| verify_case_run(scope, obj, method, form, editor.path) }
        failed = details.reject { |d| d[:ok] }

        if failed.empty?
          @pending_change = nil if @pending_change&.[](:method) == method && @pending_change[:editor] == editor
          mark_code_verified(editor_name(input), method)
          emit(:verify, plugin: editor_name(input), method: method, ok: true, cases: forms.size,
                        details: details.map { |d| d[:text] })
          "验证通过(#{forms.size} 项): #{details.map { |d| d[:text] }.join('; ')}"
        else
          rolled_back = @auto_rollback && rollback_pending(editor_name(input), method)
          msg = "验证失败(#{failed.size}/#{forms.size}): #{failed.first[:text]}"
          msg += rolled_back ? '，已自动回滚' : '（未回滚）'
          emit(:verify, plugin: editor_name(input), method: method, ok: false, actual: failed.first[:actual],
                        expected: failed.first[:expected], rolled_back: !!rolled_back)
          msg
        end
      end
    end

    # Sprint 7：显式记忆与自动沉淀 —— remember / read_memory + run 后自动记录。
    def register_remember_memory_tools
      register_tool('remember') do |input|
        input = {} if input.nil?
        who = (input['who'] || input[:who] || 'ra').to_s
        note = (input['note'] || input[:note]).to_s.strip
        kind = (input['kind'] || input[:kind] || 'fact').to_s
        status = (input['status'] || input[:status] || 'stated').to_s
        about = (input['about'] || input[:about]).to_s
        supersedes = (input['supersedes'] || input[:supersedes]).to_s
        raise '记忆内容不能为空' if note.empty?
        id = @memory.add_turn(who: who, note: note, tags: (input['tags'] || input[:tags]),
                              kind: kind, about: about, status: status, supersedes: supersedes)
        raise '记忆未落盘' unless id
        record = { id: id, kind: kind, who: who, note: note, status: status,
                   tags: normalize_tags(input['tags'] || input[:tags]) }
        emit(:remember, **record)
        "已写入记忆 #{id}（#{kind}#{status == 'confirmed' ? '/confirmed' : ''}）" + (supersedes.empty? ? '' : "，取代 #{supersedes}")
      end

      register_tool('read_memory') do |input|
        input = {} if input.nil?
        q   = (input['query'] || input[:query] || input['q']).to_s
        lim = (input['limit'] || input[:limit] || 5).to_i
        hits = @memory.recall(query: q, limit: lim)
        next '（记忆为空）' if hits.empty?
        hits.map do |t|
          rel = t[:supersedes] ? " (取代 #{t[:supersedes]})" : ''
          state = t[:status] && t[:status] != 'stated' ? "[#{t[:status]}]" : ''
          "- #{t[:id]}#{state}[#{t[:who]}] #{t[:note]}#{rel}"
        end.join("\n")
      end

      # 记忆运转的"化"侧：把一条确证记忆内化成可执行方法（apply_code/verify 同机制）。
      # @doc 溯源 memory id；记忆状态升 confirmed —— 记忆最终变成能跑的方法。
      register_tool('promote') do |input|
        input = {} if input.nil?
        mid = (input['memory'] || input[:memory]).to_s
        rec = @memory.record(mid)
        raise "未找到记忆 #{mid}" unless rec
        raise "记忆 #{mid}（#{rec[:status]}）不可内化：已废弃" if rec[:status] == 'superseded'

        code = (input['code'] || input[:code]).to_s
        method = (input['method'] || input[:method]).to_s
        plugin = (input['plugin'] || input[:plugin] || 'ra').to_s
        raise '缺少方法名与实现（method + code）' if method.empty? || code.empty?

        record = perform_apply('plugin' => plugin, 'method' => method, 'code' => code)
        @memory.confirm!(mid)
        begin
          @hub.teach(plugin, method, memory: mid)
        rescue StandardError
          nil
        end

        emit(:promote, **record.merge(memory: mid))
        "已内化记忆 #{mid} → #{record[:plugin]}##{record[:method]}（记忆已标 confirmed，@doc 溯源 #{mid}）"
      end
    end

    # 可编程验证器的单条执行：真实求值 + 三种验证形态（值相等 / 抛错 / 布尔断言）。
    # 返回值始终是 { ok:, actual:, expected:, text: }，调用方按 failed 汇总决策。
    def verify_case_run(scope, obj, method, form, path)
      args = Array(form['args'])
      arg_text = args.map(&:inspect).join(', ')

      call = proc { scope.respond_to?(method) ? scope.send(method, *args) : obj.send(method, *args) }

      if form.key?('raises')
        begin
          actual = call.call
          { ok: false, actual: actual.inspect,
            text: "#{method}(#{arg_text}) 期望抛 #{form['raises']} 但正常返回 #{actual.inspect}" }
        rescue NoMethodError, StandardError => e
          wanted = Object.const_get(form['raises'].to_s) rescue nil
          if wanted && e.is_a?(wanted)
            { ok: true, actual: nil, text: "#{method}(#{arg_text}) 抛 #{e.class} 符合预期" }
          else
            { ok: false, actual: e.class.to_s,
              text: "#{method}(#{arg_text}) 期望抛 #{form['raises']} 实际抛 #{e.class}: #{e.message}" }
          end
        end
      else
        begin
          actual = call.call
          if form.key?('assert')
            verdict = obj.instance_eval("result = #{actual.inspect}\n(#{form['assert']})", path, 1)
            if verdict
              { ok: true, actual: actual.inspect,
                text: "#{method}(#{arg_text}) 断言 #{form['assert']} 成立 (#{actual.inspect})" }
            else
              { ok: false, actual: actual.inspect,
                text: "#{method}(#{arg_text}) 断言 #{form['assert']} 不成立 (实际 #{actual.inspect})" }
            end
          else
            expected = form['expected'].to_s
            if actual.to_s == expected
              { ok: true, actual: actual, text: "#{method}(#{arg_text}) = #{actual}" }
            else
              { ok: false, actual: actual, expected: expected,
                text: "#{method}(#{arg_text}) 期望=#{expected} 实际=#{actual}" }
            end
          end
        rescue NoMethodError, StandardError => e
          { ok: false, actual: "#{e.class}: #{e.message}",
            text: "调用 #{method}(#{arg_text}) 抛 #{e.class}: #{e.message}" }
        end
      end
    end

    # run 结束后自动沉淀一条本次对话（任务 → ra 的答复，压平成单行便于召回）
    def record_active_turn(task)
      note = "#{task} → #{@state.answer || @state.error || '未完成'}"
      note = note.gsub(/\s+/, ' ').strip[0, 500]
      @memory.add_turn(who: 'ra', note: note, tags: 'auto', kind: 'event')
    rescue StandardError
      nil
    end

    # Sprint 5：learn 工具 —— Agent 把本次经验沉淀进 Knowledge 仓库。
    # 注入 knowledge: 时注册；沉淀成功发出 :learn 事件并记入 state.learned。
    def register_learn_tool
      register_tool('learn') do |input|
        input = {} if input.nil?
        lesson = (input['lesson'] || input[:lesson]).to_s.strip
        raise '学习内容不能为空' if lesson.empty?

        tags = normalize_tags(input['tags'] || input[:tags])
        id = @knowledge.add(lesson, tags: tags)
        raise '经验沉淀失败' unless id

        record = { id: id, lesson: lesson, tags: tags }
        @state.learned << record
        emit(:learn, **record)
        "已沉淀经验 #{id}"
      end
    end

    # 数组 tags（真实模型常直接给数组）归一化为逗号分隔字符串
    def normalize_tags(value)
      value = value.join(',') if value.is_a?(Array)
      value.to_s.strip
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
