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

## Sprint 2：DocHub 核心（第 3 周）

### 目标
- 实现插件注册表
- 支持按名寻址
- 支持多版本并行

### 已落地（v0.1 · 单版本读写分离）

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

## Sprint 3：动态修改能力（第 4 周）

### 目标
- 实现 DynamicMethodsModule
- 支持方法级回滚
- 验证 Refinements 作用域控制

### TDD 示例（minitest）
```ruby
# spec/dynamic_methods_spec.rb
class DynamicMethodsSpec < Minitest::Test
  def build_klass
    Class.new do
      extend RubyAgent::DynamicMethodsModule

      def original_method
        'original'
      end
    end
  end

  def test_override_then_rollback
    klass = build_klass

    klass.dynamic_method(:original_method) { 'modified' }
    assert_equal 'modified', klass.new.original_method

    klass.rollback!
    assert_equal 'original', klass.new.original_method
  end
end
```

### 新增文件
- `lib/dynamic_methods_module.rb`
- `spec/dynamic_methods_spec.rb`

---

## Sprint 4：Agent Loop 集成（第 5-6 周）

### 目标
- 实现基于 DeepSeek API 的 Agent Loop
- 读写走同一份 registry
- 验证插件热替换

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

---

## Sprint 5：知识沉淀与迭代闭环（第 7 周）

### 目标
- 实现注释解析（`# @doc`）
- 支持知识写回
- 验证迭代闭环

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
| 2 | W3 | DocHub 核心（多版本并行） | 注册表可用 | 🟡 进行中（单版本读写分离已落地） |
| 3 | W4 | 动态修改 | 可逆修改 | ⬜ 待开始 |
| 4 | W5-6 | Agent Loop | 端到端运行 | ⬜ 待开始 |
| 5 | W7 | 知识沉淀 + 闭环验证 | 迭代闭环 | ⬜ 待开始 |

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

1. **当前焦点**：Sprint 2 —— DocHub 多版本并行（`register` / `get(name, version:)`），
   为「新旧版本并行验证」补 TDD 用例（现有 `mount` / `[]` 已支持单版本读写分离）
2. **每日站会**：检查测试通过率（当前 `rake ruby_agent:test` 全绿：29 runs / 53 assertions）
3. **Sprint 评审**：每个 Sprint 末演示可运行版本
4. **持续集成**：push 即触发测试（仓库已 `git init` 并完成首次提交 `1d59620`）
5. **测试纪律**：任何声称修复某缺口的用例，都必须能通过一次变异验证把它弄红
