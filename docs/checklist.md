# 项目初始化检查清单

## Sprint 0 完成状态

### 已完成 ✅
- [x] 创建项目目录结构
- [x] 编写 Gemfile（依赖管理）
- [x] 创建 lib/ruby_agent.rb（入口）
- [x] 创建 spec/spec_helper.rb（测试配置）
- [x] 创建 spec/ruby_agent_spec.rb（示例测试）
- [x] 编写 Rakefile（构建任务）
- [x] 配置 .gitignore
- [x] 创建 docs/sprint-plan.md（迭代计划）
- [x] 创建 docs/tdd-workflow.md（TDD 规范）
- [x] 创建 docs/test-template.md（测试模板）
- [x] 更新 README.md（主文档）

### 待完成 ⏳
- [x] ~~安装依赖 (`bundle install`)~~ → 实测沙箱无 bundler；核心组件**零运行时依赖**，改用纯 minitest
- [x] 运行初始测试 (`rake ruby_agent:test`) —— 29 runs / 53 assertions / 0 failures / 1 skip
- [x] 初始化 Git 仓库 —— 已完成 `git init`，首次提交 `1d59620`（21 文件 / 2265 行）
- [ ] 配置 CI/CD（可选）

---

## Sprint 1：Doc 核心层 + DocPlugin 基础（✅ 已完成 2026-09-11）

> **已交付**：`lib/ruby_agent/doc.rb`（注释校验器 + 原子提交）、`lib/ruby_agent/doc_plugin.rb`
> （读写分离 + 回滚 + 热重载），以及 `spec/{doc,doc_plugin,doc_hub,regression_gaps}_spec.rb`。
> 下方清单保留为**过程记录**，实际实现与原规划有出入（详见 `docs/sprint-plan.md` Sprint 1）。

### 测试驱动开发

#### 第一阶段：接口定义
- [ ] `spec/doc_plugin_spec.rb` - 测试框架
- [ ] 测试插件命名
- [ ] 测试加载状态
- [ ] 测试生命周期方法

#### 第二阶段：最小实现
- [ ] `lib/doc_plugin.rb` - 插件基类
- [ ] 实现 `#name` 访问器
- [ ] 实现 `#loaded?` 状态查询
- [ ] 实现 `#load` / `#unload` 钩子

#### 第三阶段：知识声明
- [ ] 测试 `# @doc` 注释解析
- [ ] 测试元数据提取
- [ ] 实现 `metadata` 方法

---

## Sprint 2：DocHub 核心（第 3 周）✅ 已完成 2026-09-11

### 测试驱动开发

#### 阶段 1：注册表
- [x] `spec/doc_hub_spec.rb`
- [x] 测试插件注册
- [x] 测试按名查询
- [x] 测试版本管理

#### 阶段 2：挂载/卸载
- [x] 测试挂载操作
- [x] 测试卸载操作（触发回调）
- [x] 测试并发安全

#### 阶段 3：多版本并行
- [x] `spec/doc_hub_versions_spec.rb`
- [x] 测试同插件多版本注册
- [x] 测试版本切换
- [x] 测试版本隔离
- [x] 测试归位到最新版本
- [x] 测试未知版本返回 nil

---

## Sprint 3：动态修改能力（第 4 周）✅ 已完成 2026-09-11

### 测试驱动开发

#### 阶段 1：方法修改
- [x] `spec/dynamic_methods_spec.rb`（6 用例，全绿）
- [x] 测试方法重写
- [x] 测试回滚机制
- [x] 测试多次回滚幂等
- [x] 测试类方法回滚
- [x] 实现 `lib/ruby_agent/dynamic_methods.rb`（DynamicMethodsModule）

#### 阶段 2：Refinements 作用域
- [x] `spec/refinements_spec.rb`（7 用例，全绿）
- [x] 测试作用域隔离
- [x] 测试多层嵌套
- [x] 测试清理机制
- [x] 实现 `lib/ruby_agent/refinements.rb`（Refinements）

---

## Sprint 4：Agent Loop 集成（第 5-6 周）✅ 已完成 2026-09-11

### 测试驱动开发

#### 阶段 1：基础 Loop
- [x] `spec/agent_loop_spec.rb`（15 用例，全绿）
- [x] 测试 ReAct 循环
- [x] 测试事件处理
- [x] 测试工具调用
- [x] 实现 `lib/ruby_agent/llm_adapter.rb`（LLMAdapter 抽象基类 + MockLLM）
- [x] 实现 `lib/ruby_agent/agent_loop.rb`（AgentLoop + State + Step + 内置工具）

#### 阶段 2：集成 DocHub
- [x] 测试插件加载
- [x] 测试状态同步
- [x] 测试热重载

#### 阶段 3：DeepSeek 集成
- [x] `spec/deepseek_adapter_spec.rb`（16 用例，全绿；全程假 transport，零真实网络请求）
- [x] 测试 API 调用（请求构造 / 响应解析）
- [x] 测试流式输出（SSE 增量回调 / `[DONE]` / 心跳行）
- [x] 测试错误处理（4xx→APIError / 超时→TransportError / 重试上限）
- [x] 实现 `lib/ruby_agent/deepseek_adapter.rb`（DeepSeekAdapter + HTTPTransport）

---

## Sprint 5：知识沉淀与闭环（第 7 周）

### 测试驱动开发

#### 阶段 1：注释解析
- [ ] `spec/doc_parser_spec.rb`
- [ ] 测试 `# @doc` 解析
- [ ] 测试元数据提取
- [ ] 测试多行注释

#### 阶段 2：知识写回
- [ ] 测试保存机制
- [ ] 测试冲突处理
- [ ] 测试版本控制

#### 阶段 3：完整闭环
- [ ] 端到端集成测试
- [ ] 性能基准测试
- [ ] 稳定性测试

---

## 质量门禁

每个 Sprint 完成标准：
- [ ] 所有测试通过
- [ ] 测试覆盖率 > 80%
- [ ] 代码符合 RuboCop 规范
- [ ] 文档更新
- [ ] Changelog 记录

---

## 风险登记

| 风险 | 概率 | 影响 | 应对措施 |
|------|------|------|----------|
| Zeitwerk 热重载限制 | 中 | 高 | 使用专用 Loader 实例隔离 |
| Refinements 作用域复杂 | 高 | 中 | 早期编写隔离测试 |
| DeepSeek API 不稳定 | 低 | 高 | 抽象 LLM Adapter，支持 mock |
| 回滚逻辑遗漏 | 中 | 高 | 每次修改必须配对 rollback 测试 |
| **失败关闭假阳性**（H1） | 高 | 高 | 区分"注释写回/代码写回"；测试必须真注入方法体错误，禁止用注释值冒充 |
| **键类型不一致导致静默丢数据**（H2） | 高 | 高 | `teach` 入口 `method.to_s` 统一键；写回前以磁盘为准 merge；加"原有字段仍在"回归测试 |
| **注释块整体替换丢失信息**（H3） | 中 | 高 | rewrite 基于「磁盘现有字段 ∪ 本次修改」生成，保留普通注释 |
| **watch 与 teach 无锁竞态**（H4） | 中 | 高 | registry 读写加 Mutex；重载走事件队列 |
| `RubyVM` 为 CRuby 私有 API | 中 | 中 | 若目标含 JRuby/TruffleRuby，需抽象编译校验层 |

> 以上 H1–H4 均来自 `doc_demo/` 的**实际运行复现**，详见 `docs/demo-review.md`。

---

## 里程碑

| 日期 | 里程碑 | 交付物 |
|------|--------|--------|
| W1 | 项目骨架就绪 | 可运行环境 + CI |
| W2 | DocPlugin 可用 | 基础插件系统 |
| W3 | DocHub 可用 | 注册表系统 |
| W4 | 动态修改可用 | 可逆修改能力 |
| W5-6 | Agent Loop 可用 ✅ | ReAct 循环 + 事件系统 + DeepSeek Adapter（10 spec / 84 runs 全绿） |
| W7 | 完整迭代闭环 | 生产可用版本 |

---

## 下一步行动

1. ~~安装依赖~~ → 已核查：无需 bundler（核心组件零运行时依赖）
2. ~~验证环境~~ → ✅ `rake ruby_agent:test` 全绿（29 runs / 53 assertions）
3. ~~`git init` 并完成首次提交~~ → ✅ 已完成（commit `1d59620`）
4. ~~Sprint 3 —— 动态修改能力 + 回滚机制~~ → ✅ 已完成（`dynamic_methods` + `refinements`，13 用例全绿）
5. ~~Sprint 4 —— Agent Loop 集成~~ → ✅ 已完成（`llm_adapter` + `agent_loop` + `deepseek_adapter`，31 用例全绿）
6. **下一步**：Sprint 5 —— 知识沉淀与闭环（注释解析 / 自动 teach / 端到端闭环）
5. **持续**：每日站会检查进度；任何缺口修复用例须通过一次变异验证方能算数
