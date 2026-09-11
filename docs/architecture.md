# Ruby Agent 架构设计

## 总体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Agent Loop                                   │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐       │
│  │  思考层   │→│  行动层   │→│  观察层   │→│  反思层   │       │
│  │ (ReAct)   │  │ (Tools)   │  │ (Result)  │  │ (Learn)   │       │
│  └───────────┘  └───────────┘  └───────────┘  └───────────┘       │
│                            │                                      │
│                            ▼                                      │
│                    ┌───────────────┐                              │
│                    │  DocHub       │                              │
│                    │  (注册中心)   │                              │
│                    └───────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  DocPlugin    │  │  DocPlugin    │  │  DocPlugin    │
│   (插件 A)    │  │   (插件 B)    │  │   (插件 C)    │
│  - 代码逻辑   │  │  - 代码逻辑   │  │  - 代码逻辑   │
│  - 元数据     │  │  - 元数据     │  │  - 元数据     │
│  - 回滚方法   │  │  - 回滚方法   │  │  - 回滚方法   │
└───────────────┘  └───────────────┘  └───────────────┘
```

## 核心组件

### 0. Doc（核心层 · 注释校验器）★ 新增

「注释即契约」的执行者。**这是相对参考 Demo 新增的关键组件。**

Demo 的失败关闭只覆盖代码层（`RubyVM::InstructionSequence.compile`），而 `# @doc` 是**注释**，
根本不参与编译——于是 LLM 的唯一写入通道处于零校验状态：一个带换行的注释值就能逃出注释、
变成真实代码，而 `commit` 照常返回 `true`。

```ruby
# lib/ruby_agent/doc.rb
module RubyAgent
  module Doc
    DOC_LINE = /^\s*#\s*@doc\s+(\w+):\s*(.*)$/
    ALLOWED_KEYS  = %w[role note example syntax params returns since deprecated].freeze
    MAX_VALUE_LEN = 500

    # 在写盘前对注释层单独设闸，与代码层试编译互不替代
    def self.validate!(attrs)
      attrs.each do |k, v|
        key   = k.to_s
        value = v.to_s
        raise ValidationError, "非法注释键: #{key}"        unless ALLOWED_KEYS.include?(key)
        raise ValidationError, "注释值包含换行: #{key}"     if value.include?("\n")
        raise ValidationError, "注释值过长: #{key}"         if value.length > MAX_VALUE_LEN
      end
      true
    end
  end
end
```

**两条独立闸门，缺一不可：**

| 闸门 | 覆盖对象 | 手段 | 失败语义 |
|------|----------|------|----------|
| **注释层校验** | `# @doc` 的 key / value | key 白名单、禁换行、长度上限 | 拒绝写盘，返回 `false` |
| **代码层校验** | 方法体 | `RubyVM::InstructionSequence.compile` | 丢弃 `.tmp`，不 rename |

**关键特性：**
- 注释是 LLM 的**唯一写入通道**，必须独立设闸，不能指望代码层编译兜底
- 值中禁止换行——换行会让 `# @doc` 逃出注释、升级为可执行代码
- 键空间统一为 `String`（`parse` / `teach` / `commit` 三处一致），杜绝 `:solve` 与 `"solve"` 键分裂
- 提交顺序：注释校验 → 试编译 → 写 `.tmp` → `File.rename`（原子替换）

### 1. DocPlugin（文档化插件）

每个 `.rb` 文件都是一个 DocPlugin：

```ruby
# plugins/example.rb
class ExamplePlugin < DocPlugin
  # @doc role: 提供示例功能
  # @doc version: 1.0
  # @doc author: Agent
  
  def initialize
    super('example')
    @version = '1.0'
  end
  
  def load
    # 应用修改
    apply_modifications!
  end
  
  def unload
    # 撤销修改（回滚）
    revert_modifications!
  end
  
  def execute(context)
    # 插件业务逻辑
  end
end
```

**关键特性：**
- 自描述：代码即文档（`# @doc` 注释）
- 自包含：携带元数据和生命周期
- 可替换：支持版本管理

### 2. DocHub（文档中心）

```ruby
# lib/doc_hub.rb
class DocHub
  def initialize(loader)
    @loader = loader
    @registry = {}  # name -> [Plugin, Plugin, ...]  # 多版本
    @mounted = {}   # name -> current_plugin
  end
  
  def register(plugin)
    @registry[plugin.name] ||= []
    @registry[plugin.name] << plugin
  end
  
  def mount(name, version: nil)
    plugin = @registry[name]&.find { |p| version.nil? || p.version == version }
    return nil unless plugin
    
    # 卸载旧版本
    old = @mounted[name]
    old&.unload
    
    # 加载新版本
    plugin.load
    @mounted[name] = plugin
    plugin
  end
  
  def unmount(name)
    plugin = @mounted.delete(name)
    plugin&.unload
  end
  
  def get(name, version: nil)
    plugins = @registry[name] || []
    version ? plugins.find { |p| p.version == version } : plugins.last
  end
end
```

**关键特性：**
- 多版本并行：同一插件多个版本同时存在
- 按需切换：`mount(name, version: '2.0')`
- 自动回滚：卸载时触发 `unload` 回调

> **实现现状（v0.1，2026-09-11）**：第一版 DocHub 已落地，接口与上方的规划稿略有差异——
> 先采用「**读写分离**」而非多版本并行：
>
> - `mount(plugin)` —— 挂载（内部触发 `plugin.load!`）
> - `unmount(name)` / `[](name)` —— 卸载 / 按名寻址
> - `for_llm` —— **LLM 读**：汇总所有插件的知识
> - `teach(plugin_name, method, **spec)` —— **LLM 写**：定向到某个插件，失败返回 `false`
> - `watch_all(interval:)` —— 广播热重载
>
> 读写分离的意义：读通道是**聚合的、只读的**，写通道是**定向的、带回滚的**。
> LLM 不可能通过一次读操作意外改变系统状态。
> 多版本并行（`register` / `mount(name, version:)`）顺延至 Sprint 2 落地。

### 3. DynamicMethodsModule（动态方法模块）

```ruby
# lib/dynamic_methods_module.rb
module DynamicMethodsModule
  def dynamic_method(name, &block)
    @dynamic_methods ||= {}
    @dynamic_methods[name] = instance_method(name)
    define_method(name, &block)
  end
  
  def rollback!(name)
    original = @dynamic_methods&.delete(name)
    return unless original
    
    remove_method(name)
    define_method(name, original)
  end
  
  def rollback_all!
    @dynamic_methods&.each_key do |name|
      rollback!(name)
    end
  end
end
```

**关键特性：**
- 方法级粒度：只修改特定方法
- 自动回滚：保存原始方法引用
- 支持批量回滚

### 4. Zeitwerk 集成

```ruby
# lib/ruby_agent.rb
module RubyAgent
  def self.loader
    @loader ||= Zeitwerk::Loader.new.tap do |loader|
      loader.push_dir(File.expand_path('lib', __dir__))
      loader.push_dir(File.expand_path('plugins', __dir__))
      loader.setup
    end
  end
  
  def self.doc_hub
    @doc_hub ||= DocHub.new(loader)
  end
end
```

**关键特性：**
- 自动加载：按需加载文件
- 命名空间隔离：`RubyAgent::PluginX`
- 热重载：支持重新加载

### 5. Refinements 作用域控制

`RubyAgent::Refinements` 提供隔离式的动态方法精化：精化规则只在
`scope_eval` / `scope_class` 打开的词法作用域内生效，作用域之外一律无感。

```ruby
refs = RubyAgent::Refinements.new
refs.refine(String, :shout) { upcase }

"hi".shout                      # => NoMethodError（全局未受影响）
refs.scope_eval("'hi'.shout")   # => "HI"（作用域内生效）

klass = refs.scope_class(<<~RUBY)
  def greet = "hi".shout
RUBY
klass.new.greet                 # => "HI"

refs.cleanup!                   # 注销精化，可重复调用（幂等）
refs.cleaned_up?                # => true
```

**关键特性：**
- 隔离作用域：仅作用于 `scope_eval` / `scope_class` 内部，全局与新方法上下文零泄漏
- 避免全局污染：不修改核心类，精化模块为匿名 `Module.new`，无需注册全局常量
- 可嵌套、可清理：多层嵌套时内层遮蔽外层且外层存活；`cleanup!` 幂等且清理后可复用

**实现要点（`using` 的词法上下文约束）：**
Ruby 规定 `Module#using` 只能出现在**非方法**的词法上下文中，在 `def` 内调用会抛
`RuntimeError: Module#using is not permitted in methods`，且该限制取决于代码的**词法位置**，
与运行时调用栈无关。因此实现把 `using` 预封装在类体处捕获的 lambda
（`SCOPE_CLASS_BUILDER` / `SCOPE_EVAL_RUNNER`）中，由实例方法调用——既能在运行时动态激活
任意精化模块，又无需把它注册为全局常量。

## 数据流

### 正常流程

```
LLM 请求
    │
    ▼
┌───────────┐
│ Agent Loop │
└─────┬─────┘
      │
      ▼
┌───────────┐
│ DocHub    │ ← 查找可用插件
│  (Registry)│
└─────┬─────┘
      │
      ▼
┌───────────┐
│ DocPlugin │ ← 执行插件逻辑
└─────┬─────┘
      │
      ▼
┌───────────┐
│ 返回结果   │
└───────────┘
```

### 修改流程

```
LLM 提出修改方案
        │
        ▼
┌───────────────────┐
│ 1. 生成新插件代码  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ 2a. 注释层校验     │ ← key 白名单 / 禁换行 / 长度上限；失败则中止
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ 2b. 代码层试编译   │ ← RubyVM::InstructionSequence；失败则中止
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ 3. 注册新版本      │ ← 旧版本仍可用
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ 4. 挂载新版本      │ ← 旧版本 unload()
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ 5. 运行验证测试    │ ← 失败则卸载新版本
└─────────┬─────────┘
          │
     ┌────┴────┐
     │         │
    通过       失败
     │         │
     ▼         ▼
   保留      回滚
   新版本    旧版本
     │         │
     ▼         ▼
  写回知识库   记录错误
```

## 安全边界

### 硬规则（确定性代码）

```ruby
# lib/safety_guard.rb
class SafetyGuard
  DANGEROUS_METHODS = [
    'Kernel#system',
    'Kernel#exec',
    'FileUtils#rm_rf',
    'FileUtils#rm_r'
  ]
  
  def self.validate(plugin_code)
    ast = RubyVM::InstructionSequence.compile(plugin_code)
    
    # 检查危险调用
    raise SecurityError, "禁止调用危险方法" if contains_dangerous?(ast)
    
    # 检查语法正确性
    raise SyntaxError, "代码存在语法错误" unless valid_syntax?(plugin_code)
  end
  
  private
  
  def self.contains_dangerous?(ast)
    # AST 分析，检查危险方法调用
  end
  
  def self.valid_syntax?(code)
    RubyVM::InstructionSequence.compile(code)
    true
  rescue SyntaxError
    false
  end
end
```

### 注释注入防护（新增 · 来自 Doc Demo 实证）

硬规则之外还有一类更隐蔽的攻击面：**LLM 的写入通道本身**。

注释层校验器（见「核心组件 · 0. Doc」）在写盘前拦截：

| 攻击 | 拦截依据 | 后果 |
|------|----------|------|
| 值中插入换行 + 可执行代码 | `value.include?("\n")` → 拒绝 | 注释不会逃逸成真实代码 |
| 写入白名单外的 key | `ALLOWED_KEYS` 白名单 → 拒绝 | 元数据空间不被污染 |
| 超长值撑爆文件 | `MAX_VALUE_LEN = 500` → 拒绝 | 拒绝服务式写入被挡 |

> ⚠️ **测试陷阱**：验证这一层时，payload 必须是**语法合法**的代码。
> 若用 `"def (\n$$$.call"` 这类语法非法的 payload，代码层试编译会先一步拦截，
> 于是测试"通过"却毫无意义——它证明的是编译器的能力，不是注释校验器的能力。
> 正确做法：payload 语法合法、仅靠换行逃逸（见 `spec/regression_gaps_spec.rb` 缺口 2 用例）。

## 事件系统

```ruby
# lib/events.rb
module AgentEvents
  # 插件生命周期事件
  PLUGIN_LOADED = :plugin_loaded
  PLUGIN_UNLOADED = :plugin_unloaded
  PLUGIN_MODIFIED = :plugin_modified
  
  # Agent 事件
  AGENT_THINK = :agent_think
  AGENT_ACT = :agent_act
  AGENT_OBSERVE = :agent_observe
  AGENT_LEARN = :agent_learn
end

class EventBroadcaster
  def initialize
    @listeners = Hash.new { |h, k| h[k] = [] }
  end
  
  def subscribe(event, &block)
    @listeners[event] << block
  end
  
  def publish(event, payload = nil)
    @listeners[event].each { |block| block.call(payload) }
  end
end
```

## 日志与可观测性

```ruby
# lib/logger.rb
class AgentLogger
  def self.info(msg)
    log(:info, msg)
  end
  
  def self.error(msg, exception = nil)
    log(:error, msg, exception)
  end
  
  def self.plugin_event(plugin_name, event)
    info("[#{plugin_name}] #{event}")
  end
end
```

## 测试策略

### 单元测试
- 每个 DocPlugin 独立测试
- 测试 load/unload 幂等性
- 测试回滚逻辑

### 集成测试
- 测试 DocHub 多插件协作
- 测试插件版本切换
- 测试 Agent Loop 完整流程

### 端到端测试
- 模拟 LLM 修改场景
- 验证闭环迭代

### 回归与变异验证（已落地 2026-09-11）

参考 Demo 暴露的三个缺口各自固化一条回归测试，并**主动验证测试本身有效**：

| 缺口 | 回归用例（`spec/regression_gaps_spec.rb`） | 变异实验：复原缺口 → 期望变红 |
|------|-------------------------------------------|------------------------------|
| 1 键类型不匹配 | `test_gap1_symbol_and_string_method_names_share_one_registry_slot` | `key = method.to_s` 改回 `key = method` → 2 failures ✅ |
| 2 注释层零校验 | `test_gap2_illegal_doc_value_is_rejected_and_file_unchanged` | 删除 `validate!` 的换行检查 → 1 failure ✅ |
| 3 merge 语义缺失 | `test_gap3_teach_preserves_existing_doc_attrs` | 随缺口 1 变异一并变红 ✅ |

> 原则：**"测试全绿"不等于"测试有牙齿"**。凡是声称修复了某缺口的用例，都必须能用一次
> 变异把它弄红；弄不红，说明用例没测到点子上（缺口 2 早期版本就栽在这里——payload 语法
> 非法，被代码层试编译兜住，测试"通过"却与注释校验器无关）。

### 现有测试清单（29 runs / 53 assertions / 0 failures / 1 skip）

| 文件 | 覆盖内容 | 用例数 |
|------|----------|--------|
| `spec/doc_spec.rb` | 解析 / 校验 / 原子提交 | 10 |
| `spec/doc_plugin_spec.rb` | 加载 / 教学 / 回滚 / 热重载 | 6 |
| `spec/doc_hub_spec.rb` | 挂载 / 卸载 / 读写路由 | 5 |
| `spec/regression_gaps_spec.rb` | 三个缺口回归 | 5 |
| `spec/ruby_agent_spec.rb` | 组件装配（zeitwerk 缺失时 skip） | 3 |

## 性能考量

| 场景 | 优化策略 |
|------|----------|
| 插件加载 | 懒加载，按需加载 |
| 热重载 | 增量加载，只加载变更文件 |
| 并发访问 | 线程安全注册表 |
| 内存管理 | 及时释放已卸载插件 |

---

*文档版本：1.1*
*最后更新：2026-09-11*

**变更记录**
- v1.1（2026-09-11）：新增「核心组件 · 0. Doc（注释校验器）」与「注释注入防护」；
  DocHub 接口对齐实际实现（`mount` / `unmount` / `[]` / `for_llm` / `teach` / `watch_all`）；
  修改流程图补入注释层校验；补充回归与变异验证、测试清单。
- v1.0（2026-09-11）：初稿。
