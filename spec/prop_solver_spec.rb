# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/ruby_agent/prop_solver'

# 命题逻辑判定器规范 —— 纯真值枚举，证明 machine 部分自身正确（LLM 只管翻译，这里只管对）。
class PropSolverSpec < Minitest::Test
  include PropSolver

  def test_eval_leaf_and_not
    a = { 'A' => true }
    assert eval_expr('A', a)
    refute eval_expr(['not', 'A'], a)
  end

  def test_eval_binary_connectives
    { 'and' => [[true, true, true], [true, false, false]],
      'or'  => [[true, false, true], [false, false, false]],
      'imp' => [[true, false, false], [true, true, true], [false, true, true]],
      'iff' => [[true, true, true], [true, false, false]] }.each do |op, cases|
      cases.each do |p, q, expected|
        actual = eval_expr([op, 'A', 'B'], 'A' => p, 'B' => q)
        assert_equal expected, actual, "#{op}(#{p},#{q}) 期望 #{expected} 实际 #{actual}"
      end
    end
  end

  def test_all_assignments_count
    assert_equal 4, all_assignments(%w[A B]).size
    assert_equal 8, all_assignments(%w[A B C]).size
  end

  def test_modus_ponens_entails
    # A, A→B ⊨ B
    result = verify(['A', ['imp', 'A', 'B']], 'B')
    assert result[:entailed], 'modus ponens 不成立，反例应为空'
    assert_empty result[:countermodels]
  end

  def test_modus_tollens_entails
    # ¬B, A→B ⊨ ¬A
    result = verify([['not', 'B'], ['imp', 'A', 'B']], ['not', 'A'])
    assert result[:entailed]
    assert_empty result[:countermodels]
  end

  def test_affirming_consequent_has_countermodel
    # B, A→B ⊬ A（肯定后件谬误，有反例）
    result = verify(['B', ['imp', 'A', 'B']], 'A')
    refute result[:entailed], '肯定后件不该蕴涵'
    assert result[:countermodels].size > 0, '应存在反例指派'
  end

  def test_affirming_consequent_countermodel_values
    result = verify(['B', ['imp', 'A', 'B']], 'A')
    cm = result[:countermodels].first
    # 反例中 B 真，A 假：B=true, A=false, A→B=true
    assert_equal true,  cm['B']
    assert_equal false, cm['A']
    assert_equal true,  eval_expr(['imp', 'A', 'B'], cm)
  end

  def test_contradictory_premises_entails_everything
    # A ∧ ¬A ⊨ B（爆炸原理 ex falso quodlibet）
    result = verify([['and', 'A', ['not', 'A']]], 'B')
    assert result[:entailed], '矛盾前提应蕴涵任意结论（爆炸原理）'
  end

  def test_consistent_and_inconsistent
    assert consistent?(['A', 'B'])
    refute consistent?(['A', ['not', 'A']])
  end

  def test_describe_model
    d = describe_model({ 'B' => true, 'A' => false })
    assert_equal 'A=false, B=true', d
  end

  def test_countermodel_for_leaky_opaque_premise
    # 组成 vs 概率谬误的最小形式化（反直觉但有反例证明错误）
    # 前提：compose(O)=0.2（A='空气是纯氧'？简化）
    # 题：氧气占1/5，所以每次呼吸4/5概率憋死
    # 形式化：A= 空气有氧气, B=每次呼吸需氧气, C=每次缺氧
    # 显式前提：A, B
    # 显式结论：C（缺氧）
    # 缺的前提：B 不蕴含 C（需 D: 取样氧气耗尽事件=大+慢呼吸）
    # 让我们用 A,B ⊭ C（显然，差 D）
    result = verify(%w[A B], 'C')
    refute result[:entailed]
    # 至少一个反例 A=T,B=T,C=F
    assert result[:countermodels].any? { |a| a['A'] && a['B'] && !a['C'] },
           '必须存在 A=T,B=T,C=F 反例'
  end
end