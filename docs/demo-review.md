# Demo 评审：Doc / DocPlugin / DocHub 三层实现

> 评审对象：用户提供的 `doc_demo/`（doc.rb + plugin.rb + hub.rb + math_v1.rb + math_v2.rb + demo.rb）
> 方法：**实际运行**，非纸面推演。环境 Ruby 3.3.8（Debian 13 / trixie）。评审日期 2026-09-11。

---

## 一句话结论

**架构分层是对的、可以吸收；但它的三个核心承诺（失败关闭 / 可逆写回 / 注释即真相）在真实调用下有两个是失效的——这恰恰是本 Demo 最大的"更新价值"：它把「注释即真相」这条路线上最危险的实现陷阱，用可复现的方式摆了出来。**

Demo 不是反面教材，它是一份**诚实的探针**：跑得动，但跑出来的行为和它自己宣称的不一致。这些不一致，必须变成我们 Sprint 里的**验收测试用例**，否则我们会原样重犯。

---

## 一、实证方法

```
$ cd doc_demo && ruby demo.rb          # 原样运行，退出码 0
$ ruby diag.rb                          # 观察 registry 前后变化（无 watch 干扰）
$ ruby diag2.rb                         # 三组对照实验 F1/F2/F3
```

关键观测记录（原始输出已存档）：

| 实验 | 输入 | 期望 | **实测** |
|---|---|---|---|
| demo 步骤④ | `hub.teach(:math_v1, :solve, note: "…")` | 原 `role` 保留，追加 `note` | ❌ 磁盘上 `role` 那行**被吃掉**，只剩 `note` |
| diag D2 | 同上 | registry 中 `solve` 的字段增加 | ❌ 多出一个**符号键** `:solve`，字符串键 `"solve"` 原封不动 |
| F1 | 把 `def (` 当作**注释值**注入 `commit` | 编译失败、拒绝落盘 | ❌ `commit` 返回 **true**，照常落盘 |
| demo 步骤⑥ | 「故意写坏」 | 回滚，v1 毫发无伤 | ❌ 磁盘真的出现 `# @doc syntax: def (` |
| F2 | 真正的方法体语法错误 | 被 `RubyVM::InstructionSequence.compile` 拦截 | ✅ 拦截成功（机制本身没错） |
| F3 | 符号 method 调 `teach` | 原有注释保留 | ❌ 磁盘由两行注释塌缩成一行，`role`/`note` 静默丢失 |

---

## 二、值得吸收的设计（正面，应固化进架构）

1. **三层职责切得干净**
   `Doc`（无状态、只做 parse/rewrite/commit）→ `DocPlugin`（单文件生命周期）→ `DocHub`（多插件编排）。
   比我们现有 `architecture.md` 里的设想更落地：**核心层不依赖插件层，可单独测试**。这条直接采纳。

2. **`# @doc 键: 值` 紧贴 `def` 的行内注记格式**
   这是「注释即真相」原则的第一个**可执行形态**。相比现状文档里的 `# @doc "描述"`（引号字符串），键值对格式：
   - 可结构化解析（`key → value`），LLM 读得懂、写得出；
   - 天然贴近 Ruby 社区习惯（YARD / RBS 风格），迁移成本低。
   **决定：`# @doc key: value` 作为正式格式，写入 `architecture.md`。**

3. **原子提交：`.tmp` + `File.rename`**
   同目录 rename 在 POSIX 下是原子的。方向完全正确，保留。**但要注意它只保证了"文件层"原子，不保证"内存层"（见硬伤 H4）。**

4. **两阶段提交的"意识"**
   `teach` 先改内存、落盘成功才保留、失败回滚——这个顺序是对的，是"失败关闭"的正确骨架。**实现有缺陷（H2），但骨架要留。**

5. **按插件粒度的 `watch` 热重载（mtime 轮询）**
   一个插件一个线程、一个文件一个 mtime，互不干扰。对应我们「按插件重载」原则，比"全局重载"安全。方向采纳，实现需加锁（H4）。

6. **`for_llm`（读汇总）/ `teach`（写定向）的读写分离契约**
   这是 LLM 与系统之间最清晰的一组接口：读是全量视图，写是定点修改。**建议直接升格为对外 API 契约。**

7. **多版本共存 = 多个 Plugin 实例同时挂载**
   Demo 用 `hub.mount(v1); hub.mount(v2)` 两个实例并行，比我们现有设计（`@registry[name] = [Plugin, Plugin…]` 版本列表 + `mount(name, version:)` 切换）**更简单、更符合「一切皆插件」原则**——新老版本不是"同一插件的两个版本号"，而是"两个平等的插件"。
   **决定：修正 Sprint 2 的设计。**

---

## 三、实测暴露的缺陷（这才是"更新"的核心）

### H1 ⚠️ 致命：失败关闭（fail-close）在写回路径上**永不触发**，且演示的"故意写坏"是**假阳性测试**

- **现象**：把 `def (` 当注释值注入，`commit` 返回 `true`，照常落盘（F1）；demo 步骤⑥号称"编译失败，回滚"，实测磁盘真的被写进了 `# @doc syntax: def (`。
- **根因**：`rewrite_lines` 只生成 `# @doc k: v` **注释行**，注释无论写什么都是合法 Ruby；而 `commit` 用 `RubyVM::InstructionSequence.compile` 校验的正是这份"只改了注释"的新源码 → **永远编译通过** → 失败关闭分支是死代码。
- **推论**：`F2` 证明 compile 拦截语法错误的能力**本身有效**，但 Demo 里**没有任何路径能触发它**。也就是说，Demo 展示的其实只是"**文本/注释层的可逆修改**"，而被愿景批判为"太浅"的**源码层修改（改方法体）根本不存在**。
- **更新要求**：
  1. 必须显式区分**两类写回**——「改注释（元数据）」与「改代码（方法体）」。前者不需要 try-compile，后者才需要，且必须真实注入方法体错误来做测试。
  2. Sprint 的失败关闭测试用例，**禁止**用"把坏代码塞进注释值"这种写法——它是假阳性。

### H2 ⚠️ 致命：字符串键 / 符号键不一致 → 内存脏数据 + 磁盘注释**静默丢失**

- **现象**（F3）：`teach` 前 registry 为 `{"foo" => {role, note}}`；`teach(:foo, extra:)`（符号）之后变成 `{"foo" => {role, note}, :foo => {extra}}`——**两个键并存**；磁盘则由两行注释塌缩为一行 `# @doc extra: 补充`，`role`/`note` 全部丢失。
- **根因链**：
  1. `Doc.parse` 用 `$1`（String）作键 → registry 键是字符串；
  2. `hub.teach(name, :solve, …)` 传的是**符号**；
  3. `@registry[method]`（符号）查不到 → 拿到空 hash → merge 出的 attrs **不含原有字段**；
  4. `rewrite_lines` 把原 `@doc` 块**整体替换**成这份不完整的 attrs。
- **后果**：直接背叛「注释即真相」「可逆」——**写回会悄悄抹掉知识**，且调用方毫无感知（返回 true）。
- **更新要求**：
  1. **键规范化**：`teach` 入口一律 `method.to_s`，registry 全量使用 String 键；
  2. **以磁盘为准合并**：写回前重新 `parse` 磁盘现况，做 `disk_fields.merge(new_fields)`，而不是信任可能陈旧/被污染的内存 registry；
  3. 加一条"写回后原有字段仍在"的回归测试。

### H3 ⚠️ 写回语义是「整体替换」而非「增量更新」

- `src[start...def_i] = block` 无条件替换整段注释块。只要 attrs 不完整（H2 就会造成），信息必然丢失。
- **更新要求**：rewrite 应基于「磁盘现有字段 ∪ 本次修改字段」生成注释块；并保留非 `@doc` 的普通注释不动。

### H4 ⚠️ `watch` 线程与主线程共享 `@registry`，**无锁**，结果不确定

- **现象**：同一份 demo 两次运行，最终状态不同（一次内存停在 `note` 版本，一次磁盘停在 `syntax` 版本）——典型的竞态。
- `load!` 会用文件内容**整体覆盖** `@registry`，与 `teach` 的读改写并发冲突。所谓"原子提交"只覆盖了文件层。
- **更新要求**：registry 读写加 Mutex；`watch` 的重载走事件队列，不直接覆盖正在被 `teach` 修改的对象。

### 边界问题（次要，但要在解析器里定义清楚）

- `def` 正则 `(\w+)` 不覆盖 `foo?` / `foo!` / `foo=` / `[]` / `<=>` 等合法方法名；
- `def self.foo` 会被误登记为方法 `"self"`；
- 文件末尾未闭合的 `@doc`（后无 `def`）会被静默丢弃；
- `RubyVM::InstructionSequence` 是 **CRuby 私有 API**，JRuby / TruffleRuby 上不存在 → 若愿景的"Ruby 生态"包含非 MRI 实现，此处需要抽象层。

---

## 四、对现有规划的修正（Sprint 级）

| 位置 | 现状 | 修正为 |
|---|---|---|
| `architecture.md` §DocPlugin | `# @doc "描述"` | `# @doc key: value`（键值对，紧贴 `def`） |
| `architecture.md` §DocHub | `@registry[name] = [P1,P2]` + `mount(version:)` | 多版本 = **多个平等插件实例**，按 `name` 寻址 |
| `architecture.md`（新增） | — | 补「原子提交 / 两阶段提交 / 按插件 watch」三节 |
| `sprint-plan.md` Sprint 2 | 测试"版本管理/版本切换" | 改为测试"**多实例同时挂载、互不干扰**" |
| `sprint-plan.md` Sprint 5 | 只写"注释解析/写回" | 明确**区分注释写回 vs 代码写回**，后者才接 try-compile |
| `checklist.md` 风险登记 | 4 条 | 追加 H1–H4 四条实证风险 |
| 全局 | — | **`RubyVM` 依赖需抽象**（若非纯 MRI 目标） |

---

## 五、必须补的 TDD 用例（防回归，逐条对应上面的硬伤）

```ruby
# 对应 H1：失败关闭必须是"真"失败
it '拒绝会破坏方法体的写回（注入方法体错误，而非注释值）'
it '接受只改注释的写回（注释永不触发编译失败）'   # 明确语义边界

# 对应 H2：键规范化
it 'teach 传 Symbol 与 String 得到同一份 registry 键'
it '写回后磁盘上原有 @doc 字段全部保留'

# 对应 H3：增量更新
it '只改一个字段时，其余字段与普通注释不受影响'

# 对应 H4：并发
it 'watch 重载与 teach 并发时，registry 不被静默覆盖'
it '同一 demo 连续运行结果确定（无竞态）'

# 对应边界
it '正确解析 foo? / foo! / foo= / def self.foo'
```

---

## 六、附：Agnes API 连通性结论（上一轮遗留的"跑起来看看"）

- **端点**：`POST https://apihub.agnes-ai.com/v1/chat/completions` —— ✅ 可达，鉴权通过。
- **坑点 1**：请求里模型名必须用 **ID `agnes-2.5-flash`**；用户给的 `"Agnes 2.5 Flash"` 是显示名，直接传会返回 `HTTP 503 / model_not_found`。
- **坑点 2**：该模型把 token 花在 `reasoning_content` 上。`max_tokens: 128` 时 128 token **全被 reasoning 吃光**，`content` 为空、`finish_reason: length`。**Agent 调用必须给足 token 预算，并同时处理 `reasoning_content` 与 `content` 两路字段。**
- 实测成功响应：`content = "\n\n1+1 等于 2。"`，`usage: reasoning_tokens=42, text_tokens=10`。
- 可用模型（`GET /v1/models`）：`agnes-2.5-flash`、`agnes-2.5-pro`、`agnes-2.5-pro-beta/alpha`、`agnes-3.0-flash`、`agnes-2.0-flash` 等。
- **决策建议**：`architecture.md` 里的 LLM Adapter 抽象层，除 DeepSeek 外应加一个 Agnes provider；测试用 mock，避免依赖外网。

---

## 附：证据文件（可复现）

```
doc_demo/
├── demo.rb      # 原样运行：ruby demo.rb
├── diag.rb      # registry 前后对比（无 watch）
├── diag2.rb     # F1 / F2 / F3 三组对照实验
└── probe*.rb    # 实验过程产物，可删除
```
