# RA 自我迭代 —— 收官状态与严格判定（2026-09-17）

> 项目收束时的现状、实测证据、对"自我修改 / 自我成长"的严格结论，以及未结论清单。
> 不做宣传口径，只记录可复现的东西。

## 一句话结论

**"可验证的自改"是真的，"自主的成长"未被证实。**
框架能给 ra 一个安全的"改自己 → 机器验证 → 失败回滚"闭环；但在真机上，
它既不稳定（自改成功率约 1/3），也没有可测量的成长（学习带来的指标变化淹没在噪声里）。

## 能跑什么

- 核心：`Doc / DocPlugin / DocHub / AgentLoop`；插件化 + `# @doc` 注释即契约。
- 自改闭环：`read_code` → `apply_code`（试编译 + 原子落盘 + 快照）→ `verify`（独立子进程执行）
  → 失败自动回滚（`code_editor.rb` / `agent_loop.rb` / `verify_worker.rb`）。
- 知识沉淀：`learn` 写入 `lessons.rb`，下轮随 `for_llm` 注入。
- BBH 分层实验：LLM 升维抽约束 JSON，Ruby 机层穷举验证（`plugins/bbh.rb`）。
- 度量设施（本次收官新增）：`examples/bbh_grow.rb`（train/holdout 隔离）+ `examples/ra_scorecard.rb`（记分卡）。

测试：**251 runs / 1513 assertions / 0 failures / 1 skip**（`ruby -Ilib -Ispec` 全量）。

## 实测证据

### 1. BBH 基准（成绩主要由**人工机层**贡献，非 ra 自主）
| 数据集 | 成绩 |
|---|---|
| three-objects | 247/250 |
| five-objects | 239/250 |
| seven-objects | 159/250 |
| boolean_expressions | 250/250（机械可降维，无 LLM 语义层）|

### 2. 机层自修复 `examples/bbh_self_fix_demo.rb`（RA 直接改自己代码）
注入已知 `target_pos` bug，真机让 ra 修：
| 尝试 | 结果 | 失败模式 |
|---|---|---|
| 1 | ✗ | 幻觉"我无法调用工具"，只交文字方案 |
| 2 | ✗ | 写出 Python（`def ...:`），语法被拒 |
| 3 | ✓ | read_code → apply_code → verify → learn，磁盘真被改写 |
| 4 | n/a | 发现 bug 已修，中止 |

成功率 ~1/3。attempt 3 是**真实自我修改**，其实现通过全套 spec；但稳定性差，失败源于 LLM 幻觉/语言漂移。

### 3. 成长闭环 `examples/bbh_grow.rb`（语义层学错题）
基线（five_objects, rounds=2, per-round=3, holdout=5, **repeat=2**）：
| 指标 | 均值 |
|---|---|
| holdout pass | R0 **4.0** → R1 4.5 → R2 **3.5**（Δ **-0.5**，单次范围 3~4） |
| train pass | R1 **2.0** → R2 **0.5** |
| lessons 新增 | 1 |

同题、同知识、近乎零学习下指标大幅抖动，Δ 为负。**结论：噪声压倒信号；单次"6/7"不可信。**

## 严格判定

| 说法 | 判定 |
|---|---|
| ra 能改自己代码且有真实执行验证 / 回滚 | **真** |
| ra 能把经验沉淀并影响下一轮 | **真，但只是 prompt 注入** |
| ra 在"自主"进化 | **夸大**：全程有人搭脚手架、划边界、给任务、修裁判 |
| ra 重写了自身系统架构 | **假**：`agent_loop/code_editor/verify_worker` 等核心与安全层冻结 |
| 本次 BBH 成绩来自 ra 自成长 | **假**：来自人工机层修复 |
| 学习让 ra 变强 | **未证实**：holdout 无正向、稳定增益 |

根本限制：验证看似客观，但**判定标准本身是人写的、也可能错**（`rank_for` 的 bug 即"标准答案错了"）。
ra 无法自己发现"裁判判错了"，除非人把裁判拆开、喂进失败用例。

## 本次发现并修复

- **`rank_for` 尾端序向 bug**：`"finished third-to-last"` 被当作头端 `[3,:h]`，
  正确应为尾端 `[3,:t_abs]`（`plugins/bbh.rb` + twin `examples/bbh_official.rb` + `spec/bbh_rank_for_spec.rb`）。
- **成长闭环写权限漏洞**：默认 `writable_plugins: nil`（全可写），真机跑时 ra 借机往
  `plugins/bbh.rb` 塞入 `self_intro`/`test_extraction` 并重写 `target_pos`。
  已改为 `writable_plugins: []`（仅允许 learn，禁止改机层）。
- **`bbh_grow.rb` frozen string bug**：`gsub!` 在 `# frozen_string_literal: true` 下抛 `FrozenError`（该脚本此前从未真跑）。

## 未结论 / 后续优先级

1. **记分卡驱动一切**：任何"升级"必须让 **holdout 均值** 稳定抬升才算数，单次跑不看。
2. **只读模式**：被拒的 `apply_code` 仍在浪费步数——只读场景应直接不注册写工具。
3. **知识质量**：`Knowledge#add` 只做精确去重，lesson 近重复堆积（024/025/026 等）。需按 tag 合并 + 证据绑定 + 可过期。
4. **回归门禁**：`apply_code` 落盘后应强制跑全量 spec + golden，红则回滚（当前只有 verify 用例兜底）。
5. **自动发现 bug**：把"人预置 bug + 预写用例"升级为用 gradebook FAIL 做机层反事实重放，让 ra 自己定位 `rank_for` 类 bug。
6. **元层升级（长期）**：渐进 pluginize，但验证器/回滚/权限作为不可自改的 TCB 钉死；永远保留人工最终 commit。

## 复现

```bash
# 全套测试
ruby -Ilib -Ispec -e "Dir['spec/*_spec.rb'].each { |f| require File.expand_path(f) }"

# 成长闭环（train/holdout 隔离）
AGNES_API_KEY=sk-... ruby -Ilib examples/bbh_grow.rb \
  /tmp/opencode/bbh/logical_deduction_five_objects.json \
  --gradebook examples/gradebook/bbh_five_merged_20260916.json \
  --rounds 2 --per-round 3 --holdout 5

# 记分卡（多次取均值 + spec）
AGNES_API_KEY=sk-... ruby -Ilib examples/ra_scorecard.rb \
  /tmp/opencode/bbh/logical_deduction_five_objects.json \
  --gradebook examples/gradebook/bbh_five_merged_20260916.json \
  --tag baseline --rounds 2 --per-round 3 --holdout 5 --repeat 2

# 机层自修复（需先注入已知 bug，见文档头）
AGNES_API_KEY=sk-... ruby -Ilib examples/bbh_self_fix_demo.rb
```
