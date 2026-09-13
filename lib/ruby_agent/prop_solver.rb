# frozen_string_literal: true

# PropSolver —— 命题逻辑判定器（SOP-NL-02 的机器核心，纯 Ruby、零依赖、离线）。
#
# roles：LLM 把自然语言翻译成 JSON AST（变量+连接词），本引擎负责**机器推演**：
#   - eval_expr：对任意指派求值
#   - assignments：n 个变量的全部 2^n 指派（真值枚举）
#   - verify：前提集合是否蕴涵结论（Model-checking，向 Lean 借的反例模型思路）
#   - countermodels：所有让"前提真而结论假"的反例指派 —— 被偷换/缺失的隐藏前提就藏在这里
#
# AST 格式（LLM 产出、本引擎消费）：
#   { "vars": ["A","B"], "premises": [AST...], "conclusion": AST }
#   AST = "A" | ["not", e] | ["and", e1, e2] | ["or", e1, e2] |
#         ["imp", e1, e2] | ["iff", e1, e2]
#
# 这一层没有解析自然语言的功能——它只判形式，这正是 Lean 分工：语言是 foam，证明是机器。
module PropSolver
  module_function

  # —— 变量收集：从 AST 提取全部命题变量（保序去重，连接词不算变量）——
  def vars_in(*exprs)
    ops = %w[not and or imp iff]
    seen = []
    gather = lambda do |e|
      case e
      when String then seen << e unless ops.include?(e) || seen.include?(e)
      when Array then e.each { |x| gather.call(x) }
      end
    end
    exprs.each { |e| gather.call(e) }
    seen
  end

  # —— 求值：AST + 指派 {var=>bool} → true/false ——
  def eval_expr(e, assign)
    case e
    when String then assign.fetch(e)
    when Array
      op = e[0]
      case op
      when 'not' then !eval_expr(e[1], assign)
      when 'and' then eval_expr(e[1], assign) && eval_expr(e[2], assign)
      when 'or'  then eval_expr(e[1], assign) || eval_expr(e[2], assign)
      when 'imp' then !eval_expr(e[1], assign) || eval_expr(e[2], assign)
      when 'iff' then eval_expr(e[1], assign) == eval_expr(e[2], assign)
      else raise "未知连接词 #{op.inspect}"
      end
    else raise "非法 AST 节点 #{e.inspect}"
    end
  end

  # —— 全部指派：n 个变量 → 2^n 条 {name=>true/false}（保序、可复现）——
  def all_assignments(vars)
    result = []
    total = 1 << vars.size
    total.times do |mask|
      result << vars.each_with_index.to_h { |v, i| [v, ((mask >> i) & 1) == 1] }
    end
    result
  end

  # —— 模型检查：前提集合 ∧ → 结论 ——
  # 返回 { entailed:, countermodels: [assign,...] }
  def verify(premises, conclusion, extra = {})
    all = vars_in(*premises, conclusion)
    bad = all_assignments(all).select do |a|
      premises.all? { |p| eval_expr(p, a) } && !eval_expr(conclusion, a)
    end
    { entailed: bad.empty?, countermodels: bad, extra: extra }
  end

  # —— 一组前提本身是否自相矛盾（无任何模型）——
  def consistent?(premises)
    all = vars_in(*premises)
    all_assignments(all).any? { |a| premises.all? { |p| eval_expr(p, a) } }
  end

  # —— 找到让结论成立所需的"缺失前提"候选：反例指派里哪些变量组合成了障碍。
  #    返回每个反例指派（已含所有变量取值），供上层还原自然语言。 ——
  def missing_assumptions(premises, conclusion)
    v = verify(premises, conclusion)
    v[:countermodels]
  end

  # —— 反例指派 → 可读描述（机器能说的部分）——
  def describe_model(a)
    a.sort_by(&:first).map { |v, val| "#{v}=#{val}" }.join(', ')
  end

  # —— 与 ra 方法库对齐的公开别名：直接返回反例指派数组 ——
  def countermodels(premises, conclusion)
    verify(premises, conclusion)[:countermodels]
  end

  # —— 与 ra 方法库对齐的公开别名：entails?——
  def entails?(premises, conclusion)
    verify(premises, conclusion)[:entailed]
  end

  # —— 与 ra 方法库对齐的公开别名：satisfiable?——
  def satisfiable?(premises)
    consistent?(premises)
  end
end