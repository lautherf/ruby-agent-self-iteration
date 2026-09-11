# Ruby Agent 自我迭代框架 - Sprint 规划

## 方法论
- **敏捷开发**：短周期迭代（每 Sprint 1-2 周），持续交付可运行版本
- **TDD**：红→绿→重构，测试先行，驱动设计

---

## Sprint 0：项目骨架与环境搭建（本周）

### 目标
- 建立可运行的基础项目结构
- 配置开发环境和 CI 流程
- 定义核心接口契约

### 任务清单
- [x] 创建项目目录结构
- [x] 编写 Gemfile（依赖管理）
- [x] 创建 lib/ruby_agent.rb（入口）
- [x] 创建 spec/spec_helper.rb（测试基础）
- [x] 编写第一个测试（骨架验证）
- [x] 添加 Rakefile（常用任务，已切换为 minitest）
- [x] 配置 .gitignore
- [x] 环境核查：Ruby 3.3.8 / minitest 5.20.0 可用；bundle、rspec、zeitwerk 不可用 → **测试栈定为纯 minitest**

### 验收标准（minitest）
```ruby
# spec/ruby_agent_spec.rb
require_relative 'spec_helper'

class RubyAgentSpec < Minitest::Test
  def test_core_components_load_without_zeitwerk
    assert RubyAgent.const_defined?(:Doc)
    assert RubyAgent.const_defined?(:DocPlugin)
    assert RubyAgent.const_defined?(:DocHub)
  end

  def test_doc_hub_is_exposed_as_singleton
    assert_kind_of RubyAgent::DocHub, RubyAgent.doc_hub
  end
end
```

---

## Sprint 1：DocPlugin 基础实现（第 2 周）

### 目标
- 定义 DocPlugin 接口
- 实现插件加载/卸载基础逻辑
- 验证插件的生命周期管理

### 交付物（✅ 已完成 2026-09-11）

> 本 Sprint 的范围经参考 Demo 实证评估后**上移**：优先交付 `Doc` 核心层（注释校验器）
> 与 `DocPlugin`，并用回归测试固化 Demo 暴露的三个缺口。
> 缺口的成因与实跑证据见 [doc-demo-review.md](./doc-demo-review.md)。

| 交付物 | 文件 | 状态 |
|--------|------|------|
| 注释解析 / 改写 / 原子提交 | `lib/ruby_agent/doc.rb` | ✅ |
| 注释层校验（key 白名单 / 禁换行 / 长度上限） | `lib/ruby_agent/doc.rb` | ✅ |
| 插件加载 / 教学 / 观察等价回滚 / 热重载 | `lib/ruby_agent/doc_plugin.rb` | ✅ |
| 回归测试（3 个缺口） | `spec/regression_gaps_spec.rb` | ✅ 全绿 |

### Sprint 1 的红灯起点（TDD 归档）

三条用例在参考 Demo 的实现下**全部失败**，在移植实现下转绿；并用**变异验证**确认了它们的
有效性（人为复原缺口 → 测试立即变红 → 还原 → 恢复全绿）：

| 用例 | 对应缺口 | 断言要点 |
|------|----------|----------|
| `test_gap1_symbol_and_string_method_names_share_one_registry_slot` | 缺口 1：键类型不匹配 | `registry.size == 1`，不允许 `:solve` / `"solve"` 分裂 |
| `test_gap2_illegal_doc_value_is_rejected_and_file_unchanged` | 缺口 2：注释层零校验 | 换行值被拒 + 磁盘字节不变（payload 必须是**语法合法**的代码，否则会被试编译兜住，反而测不出注释层） |
| `test_gap3_teach_preserves_existing_doc_attrs` | 缺口 3：merge 缺失 | 新增 `note` 后原 `role` 仍在（内存与磁盘双验） |

### 测试栈决策（实测依据）

- 框架：**minitest**（`Gemfile` 已声明 `minitest ~> 5.0`；沙箱无 `bundle`，Rakefile 直接以 `ruby -Ilib -Ispec` 运行）
- 运行：`rake ruby_agent:test`，或 `ruby -Ilib -Ispec spec/<name>_spec.rb`
- 依赖策略：`zeitwerk` 降级为**可选**依赖，核心三层零运行时依赖、可独立测试

### TDD 循环
1. **Red**：编写失败测试
   ```ruby
   # spec/doc_plugin_spec.rb
   class DocPluginSpec < Minitest::Test
     def test_plugin_exposes_name
       plugin = RubyAgent::DocPlugin.new('test_plugin', path)
       assert_equal 'test_plugin', plugin.name
     end

     def test_load_populates_registry_from_source
       plugin = RubyAgent::DocPlugin.new('test_plugin', path)
       plugin.load!
       refute_empty plugin.registry
     end
   end
   ```
2. **Green**：实现最小代码
   ```ruby
   # lib/doc_plugin.rb
   class DocPlugin
     attr_reader :name
     def initialize(name)
       @name = name
       @loaded = false
     end
     
     def loaded?
       @loaded
     end
   end
   ```
3. **Refactor**：提取公共逻辑

### 新增文件
- `lib/doc_plugin.rb` - 插件基类
- `spec/doc_plugin_spec.rb` - 插件测试

### 验收标准
- 插件可实例化
- 插件有明确的加载状态
- 插件支持 `#load` / `#unload` 方法

---

## Sprint 2：DocHub 多版本并行（第 3 周）✅ 已完成 2026-09-11

### 目标
- 实现插件注册表
- 支持按名寻址
- 支持多版本并行

### 已落地（v0.2 · 多版本并行）

**接口**：
```ruby
hub.register(plugin_v1)                 # 版本 '1.0'
hub.register(plugin_v2)                 # 版本 '2.0'，与 v1 并存
hub.get('my_plugin')                    # => 当前（最新）版本
hub.get('my_plugin', version: '2.0')    # => plugin_v2
hub.mount('my_plugin', version: '1.0')  # 挂载指定版本
hub.mount('my_plugin')                  # 归位到最新版本
```

**对应测试**：`spec/doc_hub_versions_spec.rb`（11 用例，全绿）

| 交付物 | 文件 | 状态 |
|--------|------|------|
| 多版本存储结构（Hash-of-Hash） | `lib/ruby_agent/doc_hub.rb` | ✅ |
| 版本号比较（语义化版本数值排序） | `lib/ruby_agent/doc_plugin.rb` | ✅ |
| `register` / `get` / `mount` / `registry_for` / `unmount` | `lib/ruby_agent/doc_hub.rb` | ✅ |
| 旧接口向后兼容（`mount(plugin)` / `for_llm` / `teach` / `watch_all`） | `lib/ruby_agent/doc_hub.rb` | ✅ |
| 回归测试（11 用例，覆盖并行/切换/归位/未知版本 nil） | `spec/doc_hub_versions_spec.rb` | ✅ 全绿 |

**测试结果**：
```
doc_hub_versions_spec.rb: 11 runs, 28 assertions, 0 failures
```

### 新增文件
- `lib/ruby_agent/doc_hub.rb` ✅ 已落地（单版本 → 多版本演进）
- `spec/doc_hub_versions_spec.rb` ✅ 已落地（11 用例）

实现接口：`mount` / `unmount` / `[]` / `for_llm`（读，汇总全部插件）/ `teach`（写，定向到某插件）/ `watch_all`。
对应测试见 `spec/doc_hub_spec.rb`（minitest，5 用例）：

```ruby
# spec/doc_hub_spec.rb
class DocHubSpec < Minitest::Test
  include PluginFixture

  def build_hub(path, name = 'math')
    hub = RubyAgent::DocHub.new
    hub.mount(RubyAgent::DocPlugin.new(name, path))
    hub
  end

  def test_mount_loads_plugin_and_exposes_it_by_name
    with_plugin_file do |path|
      hub = build_hub(path)

      refute_nil hub['math']
      assert_equal 'math', hub['math'].name
    end
  end

  def test_teach_routes_to_named_plugin
    with_plugin_file do |path|
      hub = build_hub(path)

      assert quietly { hub.teach('math', :solve, note: 'hub 写入') }
      assert_equal 'hub 写入', hub['math'].registry.dig('solve', 'note')
    end
  end

  def test_teach_returns_false_for_unknown_plugin
    with_plugin_file do |path|
      refute build_hub(path).teach('nope', :solve, note: 'x')
    end
  end
  # 另有 unmount / for_llm 聚合两个用例
end
```

### 待实现（Sprint 2 目标接口 · 多版本并行）

> 以下接口**尚未实现**，为 Sprint 2 的目标设计，用于支撑「新旧版本并行验证」。
> 键空间统一为 `String`，版本号缺省时取当前（最新）版本。

```ruby
# 目标接口（尚未实现）
hub.register(plugin_v1)                 # 版本 '1.0'
hub.register(plugin_v2)                 # 版本 '2.0'，与 v1 并存
hub.get('my_plugin')                    # => 当前（最新）版本
hub.get('my_plugin', version: '2.0')    # => plugin_v2
hub.mount('my_plugin', version: '1.0')  # 挂载指定版本
```

### 新增文件
- `lib/ruby_agent/doc_hub.rb` ✅ 已落地（单版本）
- `lib/ruby_agent/plugin_registry.rb` ⬜ 待实现（多版本注册表）
- `spec/doc_hub_spec.rb` ✅ 已落地（5 用例）

---

## Sprint 3：动态修改能力（第 4 周）✅ 已完成 2026-09-11

### 目标
- 实现 DynamicMethodsModule
- 支持方法级回滚
- 验证 Refinements 作用域控制

### 已落地（v0.3 · 动态方法覆盖 + 回滚）

**接口**：
```ruby
klass.extend(RubyAgent::DynamicMethodsModule)

# 实例方法覆盖
klass.dynamic_method(:foo) { 'new' }
klass.rollback!          # 恢复所有动态实例方法

# 类方法覆盖
klass.dynamic_class_method(:bar) { 'class_new' }
klass.rollback!          # 同时恢复类方法
```

**对应测试**：`spec/dynamic_methods_spec.rb`（6 用例，全绿）

| 交付物 | 文件 | 状态 |
|--------|------|------|
| DynamicMethodsModule（方法覆盖 + 回滚） | `lib/ruby_agent/dynamic_methods.rb` | ✅ |
| 实例方法动态覆盖 | `dynamic_method` | ✅ |
| 类方法动态覆盖 | `dynamic_class_method` | ✅ |
| 批量回滚（实例 + 类） | `rollback!` | ✅ |
| 回滚幂等性 | 多次调用不报错 | ✅ |
| 回归测试（6 用例） | `spec/dynamic_methods_spec.rb` | ✅ 全绿 |

**测试结果**：
```
spec/dynamic_methods_spec.rb: 6 runs, 11 assertions, 0 failures
全量测试: 46 runs, 92 assertions, 0 failures, 1 skip
```

### 新增文件
- `lib/ruby_agent/dynamic_methods.rb` ✅ 已落地
- `spec/dynamic_methods_spec.rb` ✅ 已落地（6 用例）

---

## Sprint 3 阶段 2：Refinements 作用域 ✅ 已完成 2026-09-11

### 目标
- 实现 `RubyAgent::Refinements`：词法作用域内的动态方法精化
- 作用域隔离（全局零污染、多实例互不干扰）
- 多层嵌套遮蔽（内层精化遮蔽外层，退出后外层语义不变）
- 清理机制（`cleanup!` 释放精化模块，幂等，可重新激活）

### 关键技术结论：`using` 的词法上下文规则
`Module#using` 的合法性由**词法位置**决定，而非运行时调用栈：
- ❌ 不允许出现在 `def` 的词法上下文中 → `RuntimeError: Module#using is not permitted in methods`
- ✅ 允许出现在 `lambda` / `block` / 类体的词法上下文中

因此实现改为：**在类体（非方法）处预捕获 lambda**，lambda 体内执行
`Class.new do using refinement; class_eval(source, file, line) end`。
实例方法只负责调用 lambda。该方案无需把精化模块注册为全局常量，
顶层 / 全局 / 新方法上下文**零泄漏**（已用探针实测验证）。

```ruby
SCOPE_EVAL_RUNNER = lambda do |refinement, source, file, line|
  result = nil
  Class.new do
    using refinement
    result = class_eval(source, file, line)
  end
  result
end
```

### 接口
```ruby
refs = RubyAgent::Refinements.new
refs.refine(String, :shout) { upcase }

'hi'.shout                     # => NoMethodError（全局未受影响）
refs.scope_eval("'hi'.shout")  # => "HI"
refs.refined?(String, :shout)  # => true
refs.scope_class("def f = 'hi'.shout")  # => 匿名类，实例可见精化
refs.cleanup!                  # 释放作用域，幂等
refs.cleaned_up?               # => true
```

### 新增文件
- `lib/ruby_agent/refinements.rb` ✅ 已落地
- `spec/refinements_spec.rb` ✅ 已落地（7 用例，全绿）

### 测试结果
`7 runs, 23 assertions, 0 failures, 0 errors`

---

## Sprint 4：Agent Loop 集成（第 5-6 周）✅ 已完成 2026-09-11

### 目标
- 实现基于 DeepSeek API 的 Agent Loop
- 读写走同一份 registry
- 验证插件热替换

### 交付物

| 交付物 | 文件 | 状态 |
|--------|------|------|
| LLM 抽象基类（`chat` / `chat_stream` / `streaming?`）+ 测试用 MockLLM | `lib/ruby_agent/llm_adapter.rb` | ✅ |
| ReAct Agent Loop（State / Step / 事件系统 / 内置工具） | `lib/ruby_agent/agent_loop.rb` | ✅ |
| DeepSeek Adapter（Chat Completions + SSE 流式 + 错误分级 + 重试） | `lib/ruby_agent/deepseek_adapter.rb` | ✅ |
| Loop / 事件 / 工具调用 / DocHub 集成测试 | `spec/agent_loop_spec.rb` | ✅ 15 用例全绿 |
| Adapter 接口 / 请求构造 / 流式 / 错误分支测试 | `spec/deepseek_adapter_spec.rb` | ✅ 16 用例全绿（零真实网络请求） |

**实现要点**：
- `AgentLoop.new(hub:, llm:, max_steps: 8, system_prompt:)`；`#run(task)` 返回 Final Answer；`#register_tool` / `#invoke_tool` / `#on(type)` 链式注册；`#sync!` 热重载并广播 `:synced`。
- 事件类型：`:start` / `:llm_response` / `:tool_call` / `:observation` / `:finish` / `:max_steps` / `:error` / `:synced`。
- 工具异常被捕获为 `{ok: false, error: ...}` 并作为 observation 回灌，不中断循环。
- `DeepSeekAdapter` 的 `transport:` 可注入 → 测试用假 transport 完全离线；4xx/解析失败 → `APIError`，超时/连接失败/5xx → `TransportError`（按 `max_retries` 重试）。

### 测试驱动（minitest · 示意，接口随实现调整）
```ruby
# spec/agent_loop_spec.rb
class AgentLoopSpec < Minitest::Test
  def test_loads_plugins_on_startup
    hub = RubyAgent::DocHub.new
    hub.mount(RubyAgent::DocPlugin.new('greeting', path))

    agent = RubyAgent::AgentLoop.new(hub: hub)
    agent.run

    assert_includes agent.state.plugins, 'greeting'
  end

  def test_supports_hot_reload
    hub = RubyAgent::DocHub.new
    plugin_v1 = RubyAgent::DocPlugin.new('plugin', path)
    hub.mount(plugin_v1)

    # 改写插件源文件后，watch 感知变化并重载；registry 反映新内容
    rewrite_plugin_file(path, role: 'v2')
    plugin_v1.watch(interval: 0.01)

    assert_equal 'v2', hub['plugin'].registry.dig('solve', 'role')
  end
end
```

**回归数据**：`rake ruby_agent:test` → 10 spec / 84 runs / 214 assertions / 0 failures / 0 errors / 1 skip（skip 为 zeitwerk 未安装，预期）。

---

## Sprint 5：知识沉淀与迭代闭环（第 7 周）✅ 已完成 2026-09-11

### 目标
- 实现注释解析（`# @doc`）—— 已在 Sprint 1 前移交付 ✅
- 支持知识写回 — **Knowledge 经验仓库 + Agent `learn` 工具**
- 验证迭代闭环 — **IterationLoop**（成功标准 #5「经验写回」+ #6「下一轮从新知识出发」）

### 交付物（v0.5 · 知识沉淀 + 闭环）

| 交付物 | 文件 | 状态 |
|--------|------|------|
| Knowledge 经验仓库（doc 契约持久化 / 自动 id / 内容去重 / 原子落盘 / 线程安全） | `lib/ruby_agent/knowledge.rb` | ✅ |
| Agent `learn` 工具 + `:learn` 事件 + `state.learned`（注入 knowledge: 时注册） | `lib/ruby_agent/agent_loop.rb` | ✅ |
| IterationLoop 闭环编排（多轮执行 → reflect 沉淀 → Hub 反馈 → 下轮注入） | `lib/ruby_agent/iteration.rb` | ✅ |
| 可运行的离线闭环演示 | `examples/iteration_closed_loop.rb` | ✅ |
| 契约白名单新增 `tags` 键（经验标签） | `lib/ruby_agent/doc.rb` | ✅ |

**对应测试**：`spec/knowledge_spec.rb`（10 用例）+ `spec/iteration_spec.rb`（6 用例）。

**Knowledge 设计要点**：
- 经验不引入第二套格式，仍走「注释即契约」：每个 lesson 是 lessons.rb 里 `# @doc note: ...`
  悬空的 `def lesson_XXX\nend` 存根，天然被 DocParser / DocPlugin / for_llm 复用。
- 写回链路 = `Doc#validate!`（注释层白名单/禁换行/长度）→ `RubyVM` 试编译（代码层）
  → tmp + rename（原子替换）。任一步失败即丢弃，不落盘（失败关闭）。
- 去重按内容：重复经验返回既有 id，不产生双份。
- 并发：读-改-写全程 `Mutex#synchronize`，线程测试 8 并发零 lost update。

**IterationLoop 闭环语义**：
```
task → AgentLoop(fresh) → 任务完成 → reflect → Knowledge 沉淀
     → DocHub 里的 knowledge 插件 reload → 下一轮 system prompt 已含上一轮知识
```
- `reflect` 可注入（`state -> [{lesson:, tags:}]`）；缺省取 Agent 通过 `learn` 工具自学的经验。
- `IterationLoop` 初始化时把 Knowledge 以 `knowledge` 插件挂上 Hub，闭环对 Agent 完全透明。

**测试结果**：
```
spec/knowledge_spec.rb: 10 runs, 33 assertions, 0 failures（含 8 线程并发、原子 rename、多行拒写）
spec/iteration_spec.rb:  6 runs, 17 assertions, 0 failures（含闭环跨轮注入、learn 事件、reflect 沉淀）
全量: 12 spec / 100 runs / 264 assertions / 0 failures / 1 skip（zeitwerk 未装，预期）
```

### 验收标准（README 成功标准 #5 #6）

| 标准 | 对应测试 | 状态 |
|------|----------|------|
| Agent 把这次经验写回知识库（持久化、去重、可回读） | `knowledge_spec.rb` 全套 | ✅ |
| 下一次迭代从更新后的知识出发（跨轮闭环） | `test_next_iteration_reads_previous_lesson_in_system_prompt` | ✅ |
| Agent 自学会（learn 工具）可被闭环自动回收 | `test_default_reflect_consumes_agent_learned_lessons` | ✅ |
| 写入安全：多行注入被拒、原子落盘无半截、并发不丢 | `test_add_rejects_multiline_*` / `test_add_is_*` | ✅ |

> 命令复习：`rake ruby_agent:test` 或 `ruby -Ilib examples/iteration_closed_loop.rb`（离线闭环演示）。

---

## Sprint 6：代码级自修改闭环（第 8 周）✅ 已完成 2026-09-11

### 目标
- 让 Agent 不只改 `# @doc` 元数据，而是安全地改**方法体**（源码）。
- 代码层闭环：**apply_code → verify → 失败自动回滚 → 重试 → 验证通过**，对应
  成功标准 #3「安全地应用修改，失败自动回滚」的代码层落地。

### 交付物（v0.6 · 代码级自修改）

| 交付物 | 文件 | 状态 |
|--------|------|------|
| CodeEditor（单方法定位 / 整体替换 def..end / 试编译 / 原子落盘 / 快照栈回滚 / 作用域隔离） | `lib/ruby_agent/code_editor.rb` | ✅ |
| AgentLoop 新工具 `read_code` / `apply_code` / `verify` + 自动回滚 + 审计轨迹 | `lib/ruby_agent/agent_loop.rb` | ✅ |
| 事件 `:code_change` / `:verify` / `:rollback` | `lib/ruby_agent/agent_loop.rb` | ✅ |
| 离线自改闭环演示 | `examples/code_self_modify.rb` | ✅ |

**对应测试**：`spec/code_editor_spec.rb`（13 用例）+ `spec/code_loop_spec.rb`（6 用例）。

**CodeEditor 安全链（对齐核心原则）**：
1. 方法名强校验：新代码必须定义同名方法，杜绝"换了个方法"。
2. 代码层设闸：整文件 `RubyVM::InstructionSequence.compile`，过不了不落盘（失败关闭）。
3. 原子提交：tmp + rename 替换，与 Doc 同款，不留半截状态。
4. 快照栈：每次成功替换压栈，`rollback!` 按次恢复——修改必须可逆（可逆副作用）。
5. 作用域隔离：`scope` 用匿名 `Module` 求值当前文件，验证新实现零全局污染。
6. 并发：读-改-写 `Mutex` 全程持锁，6 线程并发替换后仍可编译回滚。

**闭环语义（AgentLoop `auto_rollback: true` 缺省开启）**：
```
apply_code（新方法体 + 压快照 + :applied） → verify（scope 真实求值）
  → 期望不符 → 自动 rollback + observation「已自动回滚」→ Agent 重试
  → 验证通过 → 审计轨迹置 :verified → 磁盘固化正确实现
```
- `state.code_changes` 全量审计：每次应用/回滚/验证通过都留痕（applied / rolled_back / verified）。
- `@pending_change` 只在 `apply_code`→`verify` 之间有效，`run` 结束即清空，跨任务无悬空回滚。

**测试结果**：
```
spec/code_editor_spec.rb: 13 runs, 28 assertions, 0 failures（含 self 方法 / 语法拒写 / 快照栈 / 并发）
spec/code_loop_spec.rb:     6 runs, 38 assertions, 0 failures（含失败自动回滚→重试成功闭环）
全量: 14 spec / 119 runs / 330 assertions / 0 failures / 1 skip（zeitwerk 未装，预期）
```

### 验收标准（成功标准 #2 #3 的代码层）

| 标准 | 对应测试 | 状态 |
|------|----------|------|
| 提出源码级修改方案并应用 | `test_apply_code_then_verify_success_marks_verified` | ✅ |
| 失败自动回滚（磁盘与 scope 观察等价恢复） | `test_verify_failure_auto_rolls_back_and_retry_succeeds` | ✅ |
| 语法错误不落盘、进程不中断 | `test_syntax_error_apply_is_captured_as_observation_and_loop_continues` | ✅ |
| 修改可逆且幂等 | `test_rollback_is_stack_like_and_idempotent` | ✅ |
| 效果零污染（匿名 Module 作用域） | `test_scope_invokes_replaced_method_isolated` | ✅ |

> 命令复习：`rake ruby_agent:test`、`ruby -Ilib examples/code_self_modify.rb`（离线自改闭环）。

### 前置修正（来自 doc_demo 实证，必读 `docs/demo-review.md`）
1. **格式定稿**：`# @doc key: value`，紧贴 `def` 上方；解析器需覆盖 `foo?` / `foo!` / `foo=` / `def self.foo` 等方法名形态。
2. **两类写回必须分开**：
   - 改注释（元数据）→ 内容校验（白名单 key、值不含换行），**不接 try-compile**；
   - 改代码（方法体）→ 才接 `RubyVM::InstructionSequence.compile` 试编译。
   - ⚠️ 禁止用"把坏代码塞进注释值"来测试失败关闭——那是假阳性（见 H1）。
3. **写回语义 = 增量 merge**，不是整体替换；写回前重新 `parse` 磁盘现况再合并（见 H2/H3）。
4. **键规范化**：`teach` 入口统一 `method.to_s`。
5. **并发**：registry 读写加锁，`watch` 重载与 `teach` 不得互相覆盖（见 H4）。
6. **原子提交**：`.tmp` + `File.rename`（文件层），并保证内存层一致。

### 验收标准

| 标准 | 对应测试 | 状态 |
|------|----------|------|
| 写回后磁盘上原有 `@doc` 字段全部保留 | `test_gap3_teach_preserves_existing_doc_attrs` | ✅ |
| Symbol / String 传入 `teach` 行为一致 | `test_gap1_symbol_and_string_method_names_share_one_registry_slot` | ✅ |
| 连续运行结果确定（无竞态） | `spec/doc_plugin_spec.rb` 热重载用例（线程必回收） | ✅ |
| 失败关闭真实触发**注释层**拦截 | `test_gap2_illegal_doc_value_is_rejected_and_file_unchanged` | ✅ |
| 白名单内单行值（含代码样文本）不误伤 | `test_validate_accepts_whitelisted_single_line_value` | ✅ |

> **已落地**（2026-09-11）：三条缺口回归测试位于 `spec/regression_gaps_spec.rb`；
> 全量 29 runs / 53 assertions / 0 failures / 1 skip，并经变异验证确认测试有效性。

---

## 里程碑与交付物

| Sprint | 日期 | 交付物 | 里程碑 | 状态 |
|--------|------|--------|--------|------|
| 0 | W1 | 项目骨架 + 测试栈 | 环境就绪 | ✅ 完成 |
| 1 | W2 | Doc 核心层 + DocPlugin（含 3 条回归红测） | 注释可安全读写 | ✅ 完成 |
| 2 | W3 | DocHub 核心（多版本并行） | 注册表可用 | ✅ 完成 |
| 3 | W4 | 动态修改 + Refinements 作用域 | 可逆修改 | ✅ 完成 |
| 4 | W5-6 | Agent Loop + LLM Adapter + DeepSeek Adapter | 端到端运行 | ✅ 完成 |
| 5 | W7 | 知识沉淀 + 闭环验证 | 迭代闭环 | ✅ 完成 |
| 6 | W8 | 代码级自修改闭环 | 安全自改 | ✅ 完成 |

> **范围前移说明**：Sprint 5 原定的"注释解析（`# @doc`）"因参考 Demo 暴露三个缺口，
> 已提前至 Sprint 1 交付并用回归测试固化。Sprint 5 相应收窄为"知识写回 + 闭环验证"。

---

## TDD 工作流规范

```
1. 写测试（Red）
2. 运行测试，确认失败
3. 实现最小代码（Green）
4. 运行测试，确认通过
5. 重构代码（Refactor）
6. 再次运行测试，确认通过
```

---

## 风险与应对

| 风险 | 应对 |
|------|------|
| Zeitwerk 热重载限制 | 使用专用 Loader 实例隔离 |
| Refinements 作用域复杂 | 早期编写隔离测试 |
| DeepSeek API 不稳定 | 抽象 LLM Adapter，支持 mock |
| 回滚逻辑遗漏 | 每次修改必须配对 rollback 测试 |

---

## 下一步行动

1. ~~Sprint 5~~ — 知识沉淀与迭代闭环 ✅ 已完成（`knowledge` + `iteration`）
2. ~~Sprint 6~~ — 代码级自修改闭环 ✅ 已完成（`code_editor` + 三项代码工具，19 用例全绿）
3. **候选**：真实 DeepSeek 链路冒烟（`deepseek_adapter` 已就绪但从未真打 api）；CI 接入；H4 竞态收尾（插件层 registry 加锁）。
4. **每日站会**：检查测试通过率（当前 `rake ruby_agent:test` 全绿：14 spec / 119 runs / 330 assertions，1 预期 skip）
5. **Sprint 评审**：每个 Sprint 末演示可运行版本（`examples/iteration_closed_loop.rb`、`examples/code_self_modify.rb`）
6. **测试纪律**：任何声称修复某缺口的用例，都必须能通过一次变异验证把它弄红
