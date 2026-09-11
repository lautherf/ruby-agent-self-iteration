# Doc Demo 参考更新价值评估

> 评估对象：用户提供的 `doc_demo/`（doc.rb / plugin.rb / hub.rb / math_v1.rb / math_v2.rb / demo.rb）
> 评估方式：**沙箱实跑复现**，非纸面阅读。环境 Ruby 3.3.8（Debian 13 trixie）。
> 评估日期：2026-09-11

---

## 一、结论速览

| 维度 | 结论 |
|------|------|
| **骨架** | ✅ 值得吸收。5 个设计点可直接进我们的架构文档与 Sprint 规划 |
| **承诺** | ❌ 不能照单全信。Demo 宣称的"写坏了自动回滚"**实测不成立**，坏内容照常落盘 |
| **根因** | ① `teach` 键类型不匹配（符号 vs 字符串）② 试编译管不到注释层 |
| **一句话** | 骨架可以抄，承诺不能信——它把"失败关闭"建在了一个**管不到注释层**的校验上 |

---

## 二、验证方法（可复现）

```
1. 将 math_v1.rb 恢复为初始态（solve 带 # @doc role）
2. ruby demo.rb      # 走完 ①~⑦ 全流程
3. ruby diag2.rb     # F1/F2/F3 三组对照实验
4. cat math_v1.rb    # 检查磁盘真实内容
```

三次执行的 `exit_code` 均为 **0**——Demo 从不报错，但行为与设计意图不符。

---

## 三、可直接吸收的 5 个价值点

| # | 价值点 | Demo 实现位置 | 为何值得吸收 | 对应我们的愿景原则 |
|---|--------|--------------|-------------|------------------|
| 1 | **`# @doc key: value` 行内注记格式** | `doc.rb` 的 `DOC_LINE = /^\s*#\s*@doc\s+(\w+):\s*(.*)$/` | 把"注释即真相"从**口号**变成**可解析结构**，代码与文档天然不分家 | 注释即真相 |
| 2 | **试编译 + `.tmp` + `rename` 原子提交** | `doc.rb#commit`（第 44-55 行） | `compile` 校验 → 写临时文件 → `rename` 原子替换，不留半截状态 | 原子提交 |
| 3 | **两阶段提交 + 观察等价回滚** | `plugin.rb#teach`（第 23-29 行）：内存先改 → 落盘成功才保留 → 失败还原 | 提供了"可逆副作用"最简可行骨架 | 可逆副作用 / 失败关闭 |
| 4 | **按插件粒度 mtime 热重载** | `plugin.rb#watch`：每 0.3s 比对 `File.mtime`，变了才 `load!` | 一个插件炸了不影响其他插件，且无需重启 | 按插件重载 |
| 5 | **mount/unmount + 读/写分离** | `hub.rb`：`for_llm`（读汇总）与 `teach`（写定向） | 多插件新旧共存、按名寻址的接口雏形 | 一切皆插件 |

> 这 5 点与愿景 6 原则高度同构，建议**直接抽取为架构文档的接口定义**。

---

## 四、必须修正的 3 个缺口（附实测证据）

### 缺口 1 ⚠️ `teach` 键类型不匹配 → registry 键分裂 + 原注释被整体覆盖

**实测证据（diag2.rb F3）：**

```
teach 前 registry: {"foo"=>{"role"=>"原始角色", "note"=>"原始备注"}}
teach 后 registry: {"foo"=>{"role"=>"原始角色", "note"=>"原始备注"}, :foo=>{"extra"=>"补充"}}
--- 磁盘内容 ---
# @doc extra: 补充
def foo
  1
end
```

- **键分裂**：同一方法同时存在字符串键 `"foo"` 与符号键 `:foo`。
- **覆盖而非合并**：磁盘上 `role`、`note` 两条注释**全部消失**，只剩 `extra`。

**根因**：`Doc.parse` 产出的键来自正则捕获 `$1`（**字符串**），而 `teach` 传入的是**符号**。于是：
- `old = @registry[method]&.dup`（`plugin.rb` 第 24 行）取不到旧值（键不匹配）；
- `(@registry[method] || {}).merge(...)` 实际 merge 到**空哈希** → 等价于整体覆盖。
- 注：第 25 行的 `spec.transform_keys(&:to_s)` 只规整了 **spec 一侧**，没有规整 `method` 本身。

**修复**：入口统一 `method = method.to_s`（parse/teach/commit 三处键空间必须一致）。

---

### 缺口 2 🔴 失败关闭对"注释层"完全无效（最严重，直接违背愿景）

**实测证据 A（diag2.rb F1）：**
```
commit 返回: true   <-- true 表示落盘成功
# @doc evil: def (
# @doc x: )]}
def foo
  1
end
```
把非法代码 `def (` 作为**注释值**注入，`commit` 照常返回 `true` 并落盘。

**实测证据 B（demo.rb ⑥ 之后，磁盘真实内容）：**
```ruby
# math_v1.rb
...
# @doc role: 从一个数里去掉另一个数
def sub(a, b)
  a - b
end

# @doc syntax: def (          # ← 声称"写坏了会回滚"，实际污染了源码文件
def solve
  sub(add(3, 5), 2)
end
```

**实测证据 C（diag2.rb F2，对照组）：** 只有当**方法体本身**语法错误时才会被拦截——`SyntaxError: unexpected 'end'`。

**根因**：`RubyVM::InstructionSequence.compile` 只校验**代码语法**，而 `# @doc` 是**注释**，根本不参与编译，因此 `compile` 必然通过。

**影响**：`# @doc` 恰恰是 **LLM 唯一的写入通道**。这意味着 LLM 可以任意污染注释层，而系统**零拦截**——这与愿景第 3 条"失败关闭"、第 4 条"注释即真相"**正面冲突**。

**修复方向**：
1. **key 白名单**（如只允许 rôle/note/example/syntax 等）；
2. **value 转义与注入防护**——当前实现中，含换行的值会**直接破坏文件结构**；
3. **写入后 parse 回读一致性校验**（真正实现"注释层的试编译"）。

---

### 缺口 3 ⚠️ merge 语义缺失（与缺口 1 同源）

**实测证据（demo.rb ④ → ⑤）：** `hub.teach(:math_v1, :solve, note: "两步运算…")` 之后：

```ruby
# 原： # @doc role: 先加后减，求最终答案
# 现： # @doc note: 两步运算，体现复合运算教学顺序
```
`solve` 原有的 `role` 注释**被覆盖丢失**（而非追加）。

**修复**：缺口 1 修复（`to_s` 统一）后，`(@registry[method] || {}).merge(...)` 即可正确保留旧键。

---

## 五、对现有规划的更新建议

| 目标文件 | 更新建议 |
|---------|---------|
| `README.md` | "注释即真相"升级为**"注释即契约"**（可解析、可校验）；"失败关闭"补注**注释层亦须校验** |
| `docs/architecture.md` | DocHub 接口对齐 `mount / unmount / for_llm / teach`；DocPlugin 生命周期对齐 `load! / teach / watch`；**新增"注释校验器"组件** |
| `docs/sprint-plan.md` | Sprint 1（DocPlugin 基础）即引入 `# @doc` 格式校验用例；Sprint 5（知识沉淀）须覆盖"坏注释注入"负例测试；建议在 Sprint 1 前置一步**锁定 `# @doc` 语法规范 + 校验器** |
| `docs/tdd-workflow.md` | 将本次三个缺口直接固化为**回归红测**（先失败、后修复） |

> 建议动作：把缺口 1/2/3 写成 3 条 failing spec，作为 Sprint 1 的红灯起点。

---

## 六、附：Agnes API 验证结果（"跑起来看看"的收尾）

| 项 | 结论 |
|----|------|
| 端点 | `POST https://apihub.agnes-ai.com/v1/chat/completions` ✅ 可用 |
| 鉴权 | ✅ 通过（首次报错是 `model_not_found`，非 401） |
| **正确 model id** | `agnes-2.5-flash`（"Agnes 2.5 Flash"是**显示名**，直接传会 503） |
| 推理模型特性 | 会消耗 `reasoning_tokens`；`max_tokens` 过小会导致 `content` 为空、`finish_reason=length`（实测 128 为空、1024 正常）→ 接入 Agent 时须**预留足量 max_tokens 并解析 `reasoning_content`** |

---

## 七、一句话总结

> Demo 的**骨架**（`# @doc` 格式、原子提交、两阶段回滚、粒度化热重载、读写分离）值得直接吸收；
> 但它的**承诺**不能信——"失败关闭"被建在一个**管不到注释层**的校验之上。
> 补上**注释层校验**与**键空间规范**后，这套设计才真正配得上我们的愿景。
