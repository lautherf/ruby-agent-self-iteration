# Ruby Agent 自我迭代框架

> **项目愿景**：让 LLM Agent 在 Ruby 生态里安全地修改自己，最坏情况只是"这次没生效"，而不是"系统崩了"。

**Agent 名字：ra** —— 循环往复（Repeat Again），持续进化，永不崩盘。
ra 对自己的"记忆"不是硬编码，而是一份用 `# @doc` 写成的**身份契约**（`plugins/ra.rb`），
和它认识其他插件共用同一套机制：**一切皆插件，ra 自己也是一个插件**。
挂上 `RubyAgent.mount_ra!(hub)` 后，ra 能通过 `whoami` / `list_docs` 读到"我是谁、我学过什么、我不能做什么"。

## 快速开始

```bash
cd ruby-agent-self-iteration

# 核心组件零运行时依赖，无需 bundler
rake ruby_agent:test

# 或直接跑单个测试文件
ruby -Ilib -Ispec spec/doc_spec.rb
ruby -Ilib -Ispec spec/regression_gaps_spec.rb

# 详细输出
rake ruby_agent:test:verbose
```

> 环境：Ruby 3.3+，测试框架 **minitest**（随 Ruby 标准发行版提供）。
> `Gemfile` 中的 `zeitwerk` 仅用于插件自动加载，属**可选依赖**——缺失时核心三层仍可独立运行、测试照常通过。

## 当前状态（2026-09-11）

Sprint 7 交付完成（**记忆即代码**）：记忆是可执行的真代码——每条记忆 = 一个 `def`，**方法体就是记忆内容**，`# @doc` 只放元数据（who/since/tags），求值 memory.rb 就能读回整份记忆（磁盘零重复、可编译、可回滚、可 git diff、可遗忘）。自动沉淀 + remember 显式记忆 + read_memory 召回 + 每轮折叠成经验。引擎层兼容真模型"一条回复塞多个 Action"的毛病（全部按序执行再认 Final）。**17 个 spec / 151 runs / 472 assertions 全绿**，真模型跨会话记忆实测通过。
（成功标准 1–6 全部闭环；代码改坏了自动回滚；ra 身份契约自明；记忆可编译可遗忘）：
> 基线：Sprint 5 终点 100 runs / 264 assertions → sprint6 119 → 真实模型适配 126 → 内化四则 130 → 记忆 145 runs。

| 层 | 文件 | 职责 |
|----|------|------|
| 核心层 | `lib/ruby_agent/doc.rb` | `parse` / `rewrite_lines` / `validate!` / `commit` |
| 插件层 | `lib/ruby_agent/doc_plugin.rb` | `load!` / `teach` / `for_llm` / `watch` |
| 中枢层 | `lib/ruby_agent/doc_hub.rb` | `mount` / `unmount` / `[]` / `for_llm` / `teach` / `watch_all` |
| 动态层 | `lib/ruby_agent/dynamic_methods.rb` | 方法覆盖 + 回滚；`lib/ruby_agent/refinements.rb` 词法作用域精化 |
| 适配层 | `lib/ruby_agent/llm_adapter.rb` | LLM 抽象基类（`chat` / `chat_stream` / `streaming?`）+ 测试用 `MockLLM` |
| 循环层 | `lib/ruby_agent/agent_loop.rb` | ReAct 循环：`run` / 工具注册（含 `whoami`）/ 事件系统 / 状态同步 |
| 供应商 | `lib/ruby_agent/deepseek_adapter.rb` | DeepSeek Chat Completions + SSE 流式 + 错误分级与重试 |
| 沉淀层 | `lib/ruby_agent/knowledge.rb` | 经验仓库：`add` / `lessons` / `load!`（doc 契约持久化，去重 + 原子落盘 + 线程安全） |
| 记忆层 | `lib/ruby_agent/memory.rb` | **记忆即代码**：`turn`/`lesson` 双通道存根 + `recall` + `consolidate!`（自动沉淀 / 显式记忆 / 折叠遗忘） |
| 闭环层 | `lib/ruby_agent/iteration.rb` | `IterationLoop`：多轮执行 → reflect 沉淀 → 下轮注入（含记忆折叠） |
| 代码层 | `lib/ruby_agent/code_editor.rb` | 代码级编辑：单方法替换 / 试编译 / 原子落盘 / 快照栈回滚 / 作用域隔离 |

其中 `spec/regression_gaps_spec.rb` 用三条回归测试固化了参考 Demo 暴露的三个缺口——
任何一次回退都会立刻变红。缺口的成因与证据见 [doc-demo-review.md](./docs/doc-demo-review.md)。

## 项目结构

```
ruby-agent-self-iteration/
├── Gemfile                       # Ruby 依赖管理（zeitwerk 可选）
├── Rakefile                      # 构建任务（minitest）
├── README.md                     # 项目愿景与现状
├── docs/
│   ├── architecture.md           # 架构设计
│   ├── sprint-plan.md            # 敏捷迭代计划
│   ├── doc-demo-review.md        # 参考 Demo 的实证评估
│   ├── demo-review.md            # 早期 Demo 评审
│   ├── tdd-workflow.md           # TDD 工作流规范
│   ├── test-template.md          # 测试模板
│   └── checklist.md              # 交付检查清单
├── examples/
│   ├── iteration_closed_loop.rb  # 离线闭环演示（知识沉淀，Sprint 5）
│   ├── code_self_modify.rb       # 离线自改演示（代码级回滚闭环，Sprint 6）
│   ├── run_agnes.rb              # 真实模型（Agnes/OpenAI 兼容）端到端自改闭环
│   ├── ask_ra.rb                 # 真实模型问 ra：你是谁（身份契约自明）
│   ├── internalize_math.rb       # 真实模型让 ra 把小学数学内化进自己
│   ├── memory_demo.rb            # 离线演示「记忆即代码」：对话=可编译的 Ruby 文件
│   └── test_memory.rb            # 真模型跨会话记忆测试：A 会话记住，B 会话 read_memory 回忆
├── plugins/
│   └── ra.rb                     # ra 身份契约：我是谁 / 我学过什么 / 我不能做什么
└── lib/
│   ├── ruby_agent.rb             # 主入口（Zeitwerk 延迟加载）
│   └── ruby_agent/
│       ├── doc.rb                # 核心层：注释解析 / 校验 / 原子提交
│       ├── doc_plugin.rb         # 插件层：加载 / 教学 / 热重载
│       ├── doc_hub.rb            # 中枢层：挂载 / 寻址 / 读写路由
│       ├── dynamic_methods.rb    # 动态修改：方法覆盖 + 回滚
│       ├── refinements.rb        # 词法作用域精化
│       ├── llm_adapter.rb        # LLM 抽象基类 + MockLLM
│       ├── agent_loop.rb         # ReAct Agent 循环（含 read_code / apply_code / verify）
│       ├── deepseek_adapter.rb   # DeepSeek 供应商实现
│       ├── knowledge.rb          # 经验仓库：沉淀 / 去重 / 原子落盘
│       ├── memory.rb             # 记忆即代码：turn/lesson 存根 + recall + 折叠
│       ├── iteration.rb          # 迭代闭环：多轮执行 + 沉淀 + 反馈
│       └── code_editor.rb        # 代码级编辑：替换 / 试编译 / 回滚 / 作用域隔离
├── spec/
│   ├── spec_helper.rb            # 测试配置与夹具
│   ├── ruby_agent_spec.rb        # 入口与组件装配
│   ├── doc_spec.rb               # 核心层：解析 / 校验 / 提交
│   ├── doc_plugin_spec.rb        # 插件层：加载 / 教学 / 回滚 / 热重载
│   ├── doc_hub_spec.rb           # 中枢层：挂载 / 路由
│   ├── doc_hub_versions_spec.rb  # 中枢层：多版本并行
│   ├── dynamic_methods_spec.rb   # 动态修改：覆盖 / 回滚
│   ├── refinements_spec.rb       # 精化作用域隔离
│   ├── agent_loop_spec.rb        # Agent Loop：循环 / 事件 / 工具 / 集成
│   ├── deepseek_adapter_spec.rb  # DeepSeek 适配器：请求 / 流式 / 错误
│   ├── regression_gaps_spec.rb   # 回归：三个缺口
│   ├── knowledge_spec.rb         # 沉淀层：增量 / 去重 / 并发 / 原子落盘
│   ├── iteration_spec.rb         # 闭环层：跨轮注入 / reflect / 自学回收
│   ├── code_editor_spec.rb       # 代码层：定位 / 替换 / 回滚 / 作用域
│   ├── code_loop_spec.rb         # 代码闭环：apply → verify → 自动回滚 → 重试
│   ├── memory_spec.rb            # 记忆层：turn/lesson 双通道 / recall / 折叠 / 并发
│   ├── memory_loop_spec.rb       # 记忆闭环：remember / 自动沉淀 / 迭代注入与折叠
│   └── ra_spec.rb                # ra 自明：身份契约 / mount_ra / whoami
└── plugins/
    └── ra.rb                     # ra 身份契约（自我认知的唯一来源）
```

## 核心架构

### 组件关系

```
┌─────────────────────────────────────────────────────────┐
│                     Agent Loop                          │
│  (通过 LLM API 驱动，读写走同一份 registry)               │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                      DocHub                             │
│  - mount / unmount 插件        - for_llm（读）           │
│  - 按名寻址 []                 - teach（写）             │
│  - watch_all 广播热重载                                  │
└─────────────────────────────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │  DocPlugin  │ │  Doc (核心) │ │  Zeitwerk   │
    │ (插件层)    │ │  注释校验器 │ │ (可选加载)  │
    └─────────────┘ └─────────────┘ └─────────────┘
           │               │
           └───────┬───────┘
                   ▼
            ┌─────────────┐
            │  原子提交    │ 试编译 + .tmp + rename
            └─────────────┘
```

### 核心概念

| 概念 | 说明 |
|------|------|
| **Doc** | 核心层。`# @doc` 的解析、改写、**注释层校验**与原子提交 |
| **DocPlugin** | 每个 `.rb` 文件都是一个插件，自带知识声明和生命周期 |
| **DocHub** | 插件注册表，支持挂载/卸载/按名寻址/读写分离 |
| **注释校验器** | 白名单 key + 禁换行 + 长度上限，为 LLM 的写通道独立设闸 |
| **Zeitwerk** | 可选。插件自动加载与热重载（缺失时核心功能不受影响） |
| **Refinements** | 词法作用域内的动态方法精化，作用域外零污染（已落地 `RubyAgent::Refinements`） |
| **LLMAdapter** | LLM 读写通道的抽象基类；`MockLLM` 让全链路测试零网络依赖 |
| **AgentLoop** | ReAct 循环：思考 → 调用工具 → 观察 → 收敛为 Final Answer 或触顶退出 |
| **DeepSeekAdapter** | 首个真实供应商实现；SSE 流式、错误分级（`APIError` / `TransportError`）与线性退避重试 |
| **Knowledge** | 经验仓库：Agent 自学 `learn` 的落点；doc 契约持久化、内容去重、原子落盘、线程安全 |
| **IterationLoop** | 迭代闭环：多轮执行 → reflect 沉淀 → Hub 反馈 → 下一轮从更新后的知识出发 |
| **CodeEditor** | 代码级编辑：单方法替换 / 整文件试编译 / 原子落盘 / 快照栈回滚 / 匿名 Module 作用域隔离 |
| **auto_rollback** | Agent 改错代码后，verify 失败即自动回滚，把 observation 回灌给 LLM 重试 |

## 核心原则

| 原则 | 含义 |
|------|------|
| **一切皆插件** | 没有特权内核，连 Agent Loop 本身都可替换 |
| **可逆副作用** | 任何修改都必须能撤销，观察等价恢复即可 |
| **失败关闭** | 加载失败保留旧版，写回失败不落盘——**注释层与代码层各自设闸** |
| **注释即契约** | `# @doc` 是唯一持久化格式，且是被强校验的写入契约，不是自由文本 |
| **原子提交** | 试编译通过才 rename，不留下半截状态 |
| **按插件重载** | 一个插件炸了不影响其他插件 |

## 开发流程

### 1. 写一个带契约的插件

```ruby
# plugins/math.rb
# @doc role: 提供基础算术能力
# @doc note: 所有方法均为纯函数
def solve(a, b)
  a + b
end
```

### 2. 挂载到 DocHub

```ruby
require 'ruby_agent'

hub = RubyAgent.doc_hub
hub.mount(RubyAgent::DocPlugin.new('math', 'plugins/math.rb'))

hub['math']            # => DocPlugin 实例
hub.for_llm            # => LLM 读：汇总所有插件的知识
```

### 3. 让 LLM 写回知识（带校验与回滚）

```ruby
# 写：定向到某个插件；失败返回 false 且磁盘不变
ok = hub.teach('math', :solve, note: '先加后减，求最终答案')

# 合并语义：原有 role 保留，新增 note
hub['math'].registry
# => {"solve" => {"role" => "提供基础算术能力", "note" => "先加后减，求最终答案"}}

# 非法写入被拒：换行值 / 白名单外 key
hub.teach('math', :solve, syntax: "合法开头\ndef injected; end")  # => false
hub.teach('math', :solve, evil_key: 'x')                          # => false
```

### 4. 热重载

```ruby
hub.watch_all(interval: 0.3)   # 按插件粒度比对 mtime，变更即重载
```

### 5. 驱动 Agent Loop（Sprint 4）

```ruby
require 'ruby_agent'

hub   = RubyAgent::DocHub.new
hub.mount(RubyAgent::DocPlugin.new('math', 'plugins/math.rb'))

# 离线跑：用内置 MockLLM，不触网
agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new)

# 或接真实供应商
agent = RubyAgent::AgentLoop.new(
  hub: hub,
  llm: RubyAgent::DeepSeekAdapter.new(api_key: ENV['DEEPSEEK_API_KEY'])
)

agent.on(:tool_call) { |e| puts "→ #{e[:name]}" }   # 事件订阅
answer = agent.run('把 math 插件的 role 改写为「基础算术」并写回')
agent.state.plugins   # => 当前已加载插件
agent.state.status    # => :done / :max_steps / :error
```

内置工具：`list_docs` / `read_docs` / `teach`（注入 `knowledge:` 后额外有 `learn`）；`llm:` 可注入任何实现 `chat` / `streaming?` 的适配器。
工具抛错会被捕获为 observation 回灌给 LLM，循环不中断。

### 6. 自我迭代闭环（Sprint 5）

```ruby
require 'ruby_agent'
require 'tmpdir'

dir = Dir.mktmpdir
hub = RubyAgent::DocHub.new
hub.mount(RubyAgent::DocPlugin.new('math', 'plugins/math.rb'))
knowledge = RubyAgent::Knowledge.new(File.join(dir, 'lessons.rb'))

iteration = RubyAgent::IterationLoop.new(
  hub: hub,
  knowledge: knowledge,
  builder: proc do
    RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new([
      "Action: learn\nAction Input: {\"lesson\": \"先看文档再动手\"}",
      'Final Answer: 完成'
    ]), knowledge: knowledge)
  end
)

iteration.run(%w[任务一 任务二])       # 每轮结束自动沉淀经验
knowledge.lessons                     # => [{id: "lesson_001", note: "先看文档再动手", ...}]
# 下一轮 Agent 的 system prompt 已包含上一轮沉淀的经验（闭环 #5 #6）
```

> 完整可运行演示：`ruby -Ilib examples/iteration_closed_loop.rb`（全离线）。
> `reflect:` 可注入来定制「如何从本轮状态提炼经验」；缺省回收 Agent 通过 `learn` 工具自学的经验。

### 7. 代码级自修改闭环（Sprint 6）

Agent 现在能安全地改**方法体**，改错了自动回滚：

```ruby
agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm)   # auto_rollback 缺省开启

agent.run('把 solve 修正为返回正确结果')
# Agent 的轨迹（MockLLM/真模型均可）：
#   apply_code: {"plugin":"math","method":"solve","code":"def solve(a,b) ... end"}
#   verify:     {"plugin":"math","method":"solve","args":[1,2],"expected":3}
```

内置工具：`list_docs` / `read_docs` / `teach` / `read_code` / `apply_code` / `verify`
（注入 `knowledge:` 后额外有 `learn`）。
- `apply_code`：应用新方法体，整文件试编译过不了不落盘（失败关闭）。
- `verify`：在**匿名 Module 作用域**真实求值；期望不符 → **自动回滚**并把
  observation「已自动回滚」回灌给 LLM → Agent 重试（成功标准 #3）。
- `state.code_changes` 全程审计：`applied → rolled_back / verified`。

> 可运行演示：`ruby -Ilib examples/code_self_modify.rb`（改错→回滚→重试→验证通过，全离线）。

## 迭代规划

详见 [sprint-plan.md](./docs/sprint-plan.md)

### Sprint 时间表

| Sprint | 周期 | 目标 | 状态 |
|--------|------|------|------|
| 0 | W1 | 项目骨架与环境 | ✅ 完成 |
| 1 | W2 | Doc 核心层 + DocPlugin 基础（含 3 条回归红测） | ✅ 完成 |
| 2 | W3 | DocHub 核心 | ✅ 完成 |
| 3 | W4 | 动态修改能力 | ✅ 完成 |
| 4 | W5-6 | Agent Loop 集成 | ✅ 完成 |
| 5 | W7 | 知识沉淀与闭环 | ✅ 完成 |
| 6 | W8 | 代码级自修改闭环 | ✅ 完成 |

## TDD 实践

遵循红-绿-重构循环，详见 [tdd-workflow.md](./docs/tdd-workflow.md)。

回归测试的"有效性"用**变异验证**确认：人为复原缺口 → 测试必须变红 → 还原 → 恢复全绿。

## 不做什么

- ❌ 不做通用 Agent 框架，只做 Ruby 生态的自我迭代方案
- ❌ 不追求物理级恢复，只保证观察等价
- ❌ 不让 LLM 碰安全边界，硬规则用确定性代码强制执行
- ❌ 不替代 Git，但让每次修改都可追溯、可回滚
- ❌ 不用"把坏代码塞进注释值"来证明失败关闭——那是假阳性

## 成功标准

一个 LLM Agent 能在 Ruby 项目里：
1. ✅ 读懂自己当前的所有插件和知识
2. ✅ 提出一个源码级修改方案
3. ✅ 安全地应用修改，失败自动回滚
4. ✅ 新旧版本并行验证
5. ✅ 把这次经验写回知识库
6. ✅ 下一次迭代从更新后的知识出发

**循环往复，持续进化，永不崩盘。**

## 贡献指南

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 遵循 TDD 流程开发（先写失败测试）
4. 确保测试通过 (`rake ruby_agent:test`)
5. 提交更改 (`git commit -am 'Add amazing feature'`)
6. 推送到分支 (`git push origin feature/amazing-feature`)
7. 创建 Pull Request

## 许可证

MIT License
