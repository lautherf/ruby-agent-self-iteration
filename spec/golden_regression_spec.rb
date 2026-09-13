# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/ruby_agent/verify_worker'

# 黄金回归集 —— ra 能力舱的离线冻结基线（不烧 LLM、不需 key）。
#
# 背景（外人反思 #7）：40 个方法此前**没有任何离线 spec 覆盖**，
# 全部正确性证明只存在于 LLM 教学循环的瞬时 verify 记录里——复盘/CI 无从复跑。
# 本 spec 把每个方法的代表算例与边界例外冻结成黄金文件（就在本文件），
# 经 RubyAgentWorker（真实隔离求值路径，与 verify 同一执行体）逐方法跑。
#
# 定位说明：
#  · 目标 = 锁"回归"：谁把基线带歪了，立即红；
#  · 不是"正确性"的初判证据（那是每门课 verify 循环的职责）——golden 是冻结的基线快照，
#    其数值在录入时已按契约逐条人工核验（上方 one-off 求值脚本对齐）。
# 会将 golden 与 ra.rb 同步演进：改契约必须同步改本文件对应算例。
#
# 形态与 verify 完全一致：expected（值相等）/ raises（异常类）/ assert（布尔断言）。
GOLDEN = {
  'add' => [{ 'args' => [2, 3], 'expected' => '5' },
            { 'args' => [-2, 3.5], 'expected' => '1.5' }],
  'sub' => [{ 'args' => [10, 4], 'expected' => '6' }],
  'mul' => [{ 'args' => [3, 4], 'expected' => '12' }],
  'div' => [{ 'args' => [7, 2], 'expected' => '3.5' },
            { 'args' => [5, 0], 'raises' => 'ArgumentError' }],
  'tone_of' => [{ 'args' => ['hǎo'], 'expected' => '3' },
                { 'args' => ['ma'], 'expected' => '0' }],
  'is_hanzi?' => [{ 'args' => ['中'], 'expected' => 'true' },
                  { 'args' => ['a'], 'expected' => 'false' }],
  'hanzi_count' => [{ 'args' => ['你好世界ab'], 'expected' => '4' },
                    { 'args' => [''], 'expected' => '0' }],
  'sentence_type' => [{ 'args' => ['你好？'], 'expected' => '疑问' },
                      { 'args' => ['走！'], 'expected' => '感叹' },
                      { 'args' => ['好。'], 'expected' => '陈述' },
                      { 'args' => ['x'], 'expected' => '未知' }],
  'gcd' => [{ 'args' => [12, 18], 'expected' => '6' },
            { 'args' => [-12, 18], 'expected' => '6' },
            { 'args' => [0, 0], 'expected' => '0' }],
  'is_prime?' => [{ 'args' => [2], 'expected' => 'true' },
                  { 'args' => [4], 'expected' => 'false' },
                  { 'args' => [97], 'expected' => 'true' },
                  { 'args' => [1], 'expected' => 'false' }],
  'abs' => [{ 'args' => [-5], 'expected' => '5' },
            { 'args' => [0], 'expected' => '0' },
            { 'args' => [-2.5], 'expected' => '2.5' }],
  'lcm' => [{ 'args' => [4, 6], 'expected' => '12' },
            { 'args' => [-4, 6], 'expected' => '12' },
            { 'args' => [0, 9], 'expected' => '0' }],
  'factorial' => [{ 'args' => [0], 'expected' => '1' },
                  { 'args' => [5], 'expected' => '120' },
                  { 'args' => [-1], 'raises' => 'ArgumentError' }],
  'permutation' => [{ 'args' => [5, 2], 'expected' => '20' },
                    { 'args' => [0, 0], 'expected' => '1' },
                    { 'args' => [3, 3], 'expected' => '6' },
                    { 'args' => [3, 4], 'raises' => 'ArgumentError' }],
  'combination' => [{ 'args' => [5, 2], 'expected' => '10' },
                    { 'args' => [10, 3], 'expected' => '120' },
                    { 'args' => [0, 0], 'expected' => '1' }],
  'arithmetic_sum' => [{ 'args' => [1, 1, 5], 'expected' => '15' },
                       { 'args' => [2, 0, 4], 'expected' => '8' },
                       { 'args' => [1, 2, 0], 'expected' => '0' }],
  'dot' => [{ 'args' => [[1, 2, 3], [4, 5, 6]], 'expected' => '32' },
            { 'args' => [[], []], 'expected' => '0' },
            { 'args' => [[1], [2, 3]], 'raises' => 'ArgumentError' }],
  'mat_mul' => [{ 'args' => [[[1, 2], [3, 4]], [[5, 6], [7, 8]]], 'expected' => '[[19, 22], [43, 50]]' },
                { 'args' => [[[1, 2]], [[3], [4]]], 'expected' => '[[11]]' },
                { 'args' => [[[1, 2], [3, 4]], [[5, 6]]], 'raises' => 'ArgumentError' }],
  'transpose' => [{ 'args' => [[[1, 2, 3], [4, 5, 6]]], 'expected' => '[[1, 4], [2, 5], [3, 6]]' },
                  { 'args' => [[]], 'expected' => '[]' }],
  'vector_norm' => [{ 'args' => [[3, 4]], 'expected' => '5.0' },
                    { 'args' => [[1, 1, 1, 1]], 'expected' => '2.0' }],
  'softmax' => [{ 'args' => [[0, 0]], 'expected' => '[0.5, 0.5]' },
                { 'args' => [[]], 'expected' => '[]' }],
  'argmax' => [{ 'args' => [[1, 3, 3, 2]], 'expected' => '1' },
               { 'args' => [[]], 'raises' => 'ArgumentError' },
               { 'args' => ['x'], 'raises' => 'ArgumentError' }],
  'entropy' => [{ 'args' => [[0.5, 0.5]], 'expected' => '1.0' },
                { 'args' => [[]], 'expected' => '0.0' },
                { 'args' => [[0.5, -0.5]], 'raises' => 'ArgumentError' }],
  'cross_entropy' => [{ 'args' => [[1, 0], [0.5, 0.5]], 'expected' => '1.0' },
                      { 'args' => [[1], [0.5, 0.5]], 'raises' => 'ArgumentError' }],
  'implication' => [{ 'args' => [true, false], 'expected' => 'false' },
                    { 'args' => [false, true], 'expected' => 'true' }],
  'biconditional' => [{ 'args' => [true, false], 'expected' => 'false' },
                      { 'args' => [true, true], 'expected' => 'true' }],
  'xor' => [{ 'args' => [true, false], 'expected' => 'true' },
            { 'args' => [true, true], 'expected' => 'false' }],
  'nand' => [{ 'args' => [true, true], 'expected' => 'false' },
             { 'args' => [true, false], 'expected' => 'true' }],
  'nor' => [{ 'args' => [false, false], 'expected' => 'true' },
            { 'args' => [true, false], 'expected' => 'false' }],
  'law_of_contrapositive' => [{ 'args' => [true, false], 'expected' => 'true' },
                              { 'args' => [true, true], 'expected' => 'true' }],
  'de_morgan_nand' => [{ 'args' => [true, false], 'expected' => 'true' },
                       { 'args' => [true, true], 'expected' => 'true' }],
  'absorption_law' => [{ 'args' => [true, true], 'expected' => 'true' },
                       { 'args' => [false, true], 'expected' => 'true' }],
  'excluded_middle' => [{ 'args' => [true], 'expected' => 'true' },
                        { 'args' => [false], 'expected' => 'true' }],
  'modus_ponens' => [{ 'args' => [true, false], 'expected' => 'false' },
                     { 'args' => [false, true], 'expected' => 'true' }],
  'modus_tollens' => [{ 'args' => [true, false], 'expected' => 'false' },
                      { 'args' => [false, true], 'expected' => 'true' }],
  'de_morgan_nor' => [{ 'args' => [true, false], 'expected' => 'true' },
                      { 'args' => [false, false], 'expected' => 'true' }],
  'law_of_equivalence' => [{ 'args' => [true, false], 'expected' => 'true' },
                           { 'args' => [true, true], 'expected' => 'true' }],
  # ── SOP-NL-02 验证器组（机器推演侧）──
  'eval_formula' => [{ 'args' => [['imp', 'A', 'B'], { 'A' => true, 'B' => false }], 'expected' => 'false' },
                     { 'args' => [['imp', 'A', 'B'], { 'A' => false, 'B' => true }], 'expected' => 'true' },
                     { 'args' => [['iff', 'A', 'B'], { 'A' => true, 'B' => true }], 'expected' => 'true' }],
  'formula_vars' => [{ 'args' => [['imp', 'A', 'B'], 'B'], 'expected' => '["A", "B"]' },
                     { 'args' => [['and', 'C', 'A']], 'expected' => '["C", "A"]' }],
  'all_assignments' => [{ 'args' => [['A', 'B']], 'assert' => 'result.size == 4 && result.uniq.size == 4 && result.all? { |a| a.is_a?(Hash) && a.keys.sort == %w[A B] && a.values.all? { |v| v == true || v == false } }' }],
  'entails?' => [{ 'args' => [[['imp', 'A', 'B'], 'A'], 'B'], 'expected' => 'true' },
                 { 'args' => [[['imp', 'A', 'B'], 'B'], 'A'], 'expected' => 'false' },
                 { 'args' => [['A', ['not', 'A']], 'B'], 'expected' => 'true' }],
  'countermodels' => [{ 'args' => [['B', ['imp', 'A', 'B']], 'A'], 'expected' => '[{"B"=>true, "A"=>false}]' },
                      { 'args' => [['A', ['imp', 'A', 'B']], 'B'], 'expected' => '[]' }],
  'satisfiable?' => [{ 'args' => [['A', 'B']], 'expected' => 'true' },
                     { 'args' => [['A', ['not', 'A']]], 'expected' => 'false' }]
}.freeze

# 身份契约方法与类的对应不需要执行体，数量对齐审计报告即可。
IDENTITY_METHODS = %w[self_intro what_i_learned what_i_must_not].freeze

class GoldenRegressionSpec < Minitest::Test
  RA_PLUGIN = File.expand_path('../plugins/ra.rb', __dir__)

  def test_every_ra_method_is_frozen_in_golden
    src = File.read(RA_PLUGIN)
    methods = src.scan(RubyAgent::Doc::METHOD_DEF_RE).flatten.map(&:to_s)
    golden = (GOLDEN.keys + IDENTITY_METHODS)

    missing = methods - golden
    assert_empty missing, "下列方法不在黄金回归集里（改契约必须同步冻结基线）: #{missing.join(', ')}"

    stale = golden - methods
    assert_empty stale, "黄金集里有文件已不存在的过时条目: #{stale.join(', ')}"
  end

  def test_golden_cases_pass_against_isolation_worker
    failures = []
    GOLDEN.each do |method, forms|
      res = RubyAgentWorker.run(
        'file' => RA_PLUGIN, 'method' => method, 'forms' => forms
      )
      bad = res.select { |r| !r[:ok] }
      failures.concat(bad.map { |b| "  #{b[:text]}" })
    end

    assert_empty failures, "黄金回归失败 #{failures.size} 条：\n#{failures.join("\n")}"
  end

  def test_golden_coverage_reports_method_count
    assert_equal 46, GOLDEN.size + IDENTITY_METHODS.size, '黄金集与 audit 报告 A 舱方法数应一致'
  end
end