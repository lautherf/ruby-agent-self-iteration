# frozen_string_literal: true

require_relative 'spec_helper'

# 属性回归（机器出卷）—— 一条规则 = 一个出卷机。
#
# 动机（外人反思 #4/⑥）出卷自动化：人工逐题写期望表易错（modus_tollens 判分表翻车过两次）。
# 属性测试把"人工期望"替换成"数学性质 + 随机枚举实例"：
#   性质（如 gcd(a,b)==gcd(b,a)）一旦写下，seed 随机生成器自动出无限道新题——不是背题，
#   且证明蕴含在关系里，判分即验证。
#
# 与 golden 的分工：
#   · golden_regression_spec ＝ 冻结的**具体实例**基线（回归锁）
#   · property_regression_spec ＝ **性质**证明（泛化证据），覆盖 golden 之外的新增参数组合
# 两者都离线、零 LLM、跑任意次零成本。
#
# 注意：这里直接 require 插件求解（数学关系检查），隔离恶意 assert 不是本 spec 的职责
# （那是 verify_worker 的；golden 已走隔离路径）。
class PropertyRegressionSpec < Minitest::Test
  RA_PLUGIN = File.expand_path('../plugins/ra.rb', __dir__)

  def setup
    srand 20_260_913 # 固定种子：每 seed 都是一次全新出卷，但可复现
    @mod = Module.new
    @mod.module_eval(File.read(RA_PLUGIN))
    @obj = Object.new.extend(@mod)
  end

  def rand_ints(n, lo = 0, hi = 12)
    @obj ||= nil
    sample = Array.new(n) { rand(lo..hi) }
    sample
  end

  def assert_prop(label, &)
    assert yield, "性质不成立：#{label}"
  end

  # ── 算术群 ──────────────────────────────────────────────
  def test_add_commutative_and_associative
    40.times do
      a, b, c = rand_ints(3, -20, 20)
      assert_prop("add 交换 add(#{a},#{b})") { @obj.add(a, b) == @obj.add(b, a) }
      assert_prop("add 结合 (add(add(#{a},#{b}),#{c}))") { @obj.add(@obj.add(a, b), c) == @obj.add(a, @obj.add(b, c)) }
    end
  end

  def test_mul_commutative_and_identity
    40.times do
      a, b = rand_ints(2, -15, 15)
      assert_prop("mul 交换") { @obj.mul(a, b) == @obj.mul(b, a) }
      assert_prop("mul 乘1") { @obj.mul(a, 1) == a }
    end
  end

  # ── 数论群 ──────────────────────────────────────────────
  def test_gcd_properties
    40.times do
      a, b = rand_ints(2, 1, 100)
      g = @obj.gcd(a, b)
      assert_prop("gcd 交换 gcd(#{a},#{b})==gcd(#{b},#{a})") { @obj.gcd(b, a) == g }
      assert_prop("gcd(#{a},#{b})=#{g} 必须整除 a 和 b") { a % g == 0 && b % g == 0 }
    end
    assert_prop('gcd(a,a)==a') { (1..50).all? { |a| @obj.gcd(a, a) == a } }
    assert_prop('gcd(a,0)==a') { (1..50).all? { |a| @obj.gcd(a, 0) == a } }
  end

  def test_lcm_is_common_multiple
    40.times do
      a, b = rand_ints(2, 1, 60)
      m = @obj.lcm(a, b)
      assert_prop("lcm(#{a},#{b}) 是公倍数") { m % a == 0 && m % b == 0 }
      assert_prop("lcm 交换") { @obj.lcm(b, a) == m }
    end
  end

  def test_factorial_recurrence
    assert_prop('0!==1') { @obj.factorial(0) == 1 }
    (1..15).each do |n|
      assert_prop("factorial(#{n})==n*factorial(#{n - 1})") { @obj.factorial(n) == n * @obj.factorial(n - 1) }
    end
  end

  def test_combination_symmetry_and_recurrence
    (0..12).each do |n|
      (0..n).each do |k|
        c = @obj.combination(n, k)
        assert_prop("C(#{n},#{k})==C(#{n},#{n - k})") { @obj.combination(n, n - k) == c }
        if n > 0 && k > 0 && k < n
          assert_prop("C(#{n},#{k})==C(#{n - 1},#{k})+C(#{n - 1},#{k - 1})") do
            c == @obj.combination(n - 1, k) + @obj.combination(n - 1, k - 1)
          end
        end
      end
    end
  end

  def test_arithmetic_sum_recurrence
    30.times do
      a1, d, n = rand_ints(3, 0, 20)
      assert_prop("S(#{a1},#{d},#{n}) 满足差分") { @obj.arithmetic_sum(a1, d, n + 1) == @obj.arithmetic_sum(a1, d, n) + a1 + n * d }
    end
    assert_prop('S(...,0)==0') { @obj.arithmetic_sum(3, 2, 0) == 0 }
  end

  # ── 向量/矩阵群 ─────────────────────────────────────────
  def test_dot_commutative_and_annihilation
    20.times do
      n = rand(1..8)
      v = Array.new(n) { rand(-5..5) }
      w = Array.new(n) { rand(-5..5) }
      assert_prop('dot 对称') { @obj.dot(v, w) == @obj.dot(w, v) }
      assert_prop('dot 与零向量=0') { @obj.dot(v, Array.new(n, 0)) == 0 }
    end
  end

  def test_transpose_involution
    20.times do
      rows = rand(1..5)
      cols = rand(1..6)
      m = Array.new(rows) { Array.new(cols) { rand(0..9) } } # 矩形：每行长度必须一致，否则 transpose 语义不定
      assert_prop('transpose(transpose(m))==m') { @obj.transpose(@obj.transpose(m)) == m }
    end
  end

  def test_matmul_identity_and_associativity
    15.times do
      a = Array.new(rand(1..3)) { Array.new(2) { rand(-5..5) } } # m×2，仅 A·I 要求 a 行数任意、列数=2
      id = [[1, 0], [0, 1]]
      assert_prop('A·I==A') { @obj.mat_mul(a, id) == a }
    end
    10.times do
      a = Array.new(2) { [rand(-3..3), rand(-3..3)] } # 2×2：I·A 需要 a 行数=2
      id = [[1, 0], [0, 1]]
      assert_prop('I·A==A') { @obj.mat_mul(id, a) == a }
      b = Array.new(2) { [rand(-3..3), rand(-3..3)] }
      c = Array.new(2) { [rand(-3..3), rand(-3..3)] }
      left = @obj.mat_mul(@obj.mat_mul(a, b), c)
      right = @obj.mat_mul(a, @obj.mat_mul(b, c))
      assert_prop('矩阵乘结合律') { left == right }
    end
  end

  # ── 概率/信息论群 ───────────────────────────────────────
  def test_softmax_is_distribution
    20.times do
      v = Array.new(rand(1..10)) { rand(-10..10) }
      s = @obj.softmax(v)
      assert_prop('softmax 元素∈[0,1]') { s.all? { |x| x >= 0 && x <= 1 } }
      # 四舍五入到 4 位小数：n 项每项 ≤5e-5 误差，总和容差放 1e-2
      assert_prop('softmax 总和≈1') { (s.sum - 1).abs < 1e-2 }
    end
  end

  def test_entropy_uniform_and_singleton
    assert_prop('4均匀熵=2') { (@obj.entropy([0.25, 0.25, 0.25, 0.25]) - 2.0).abs < 1e-6 }
    assert_prop('2均匀熵=1') { (@obj.entropy([0.5, 0.5]) - 1.0).abs < 1e-6 }
    assert_prop('单点熵=0') { @obj.entropy([1.0]) == 0.0 }
    15.times do
      v = Array.new(rand(2..6)) { rand(1..9).to_f }
      s = v.sum
      uniform = v.map { |x| x / s }
      shuffled = uniform.shuffle
      e1 = @obj.entropy(uniform)
      e2 = @obj.entropy(shuffled)
      assert_prop('熵对分布置换不变') { (e1 - e2).abs < 1e-6 }
    end
  end

  # ── 布尔逻辑群 ──────────────────────────────────────────
  def test_boolean_laws_hold_over_full_table
    bits = [true, false]
    bits.product(bits).each do |p, q|
      assert_prop("逆否等价律 #{p},#{q}") { @obj.law_of_contrapositive(p, q) }
      assert_prop("德摩根Ⅱ #{p},#{q}") { @obj.de_morgan_nand(p, q) }
      assert_prop("德摩根Ⅰ #{p},#{q}") { @obj.de_morgan_nor(p, q) }
      assert_prop("吸收律 #{p},#{q}") { @obj.absorption_law(p, q) }
      assert_prop("逻辑等价律 #{p},#{q}") { @obj.law_of_equivalence(p, q) }
    end
    [true, false].each do |p|
      assert_prop("排中律 #{p}") { @obj.excluded_middle(p) }
    end
  end

  def test_boolean_primitives_match_truth_tables
    # 原子门直接对照真值表（不是互相验证，而是独立定义）
    tt_bicond = ->(p, q) { p == q }
    tt_nand = ->(p, q) { !(p && q) }
    tt_nor = ->(p, q) { !(p || q) }
    [true, false].product([true, false]).each do |p, q|
      assert_prop("biconditional #{p},#{q}") { @obj.biconditional(p, q) == tt_bicond.call(p, q) }
      assert_prop("nand #{p},#{q}") { @obj.nand(p, q) == tt_nand.call(p, q) }
      assert_prop("nor #{p},#{q}") { @obj.nor(p, q) == tt_nor.call(p, q) }
    end
  end

  # ── 命题验证器群（SOP-NL-02 融合）──────────────────────
  def test_solver_reasoning_laws_over_propositions
    assert_prop('自反：A ⊢ A') { @obj.entails?(['A'], 'A') }
    assert_prop('排中律可证：⊢ A∨¬A') { @obj.entails?([], ['or', 'A', ['not', 'A']]) }
    assert_prop('德摩根可证：¬(A∧B) ⊢ ¬A∨¬B') do
      @obj.entails?([['not', ['and', 'A', 'B']]], ['or', ['not', 'A'], ['not', 'B']])
    end
    assert_prop('双重否定可证：A ⊢ ¬¬A') { @obj.entails?(['A'], ['not', ['not', 'A']]) }
    assert_prop('肯定后件不可证（有反例）') { !@obj.entails?([['imp', 'A', 'B'], 'B'], 'A') }
    assert_prop('矛盾前提爆炸：A∧¬A ⊢ B') { @obj.entails?([['and', 'A', ['not', 'A']]], 'B') }
    assert_prop('反例模型全部满足"前提真结论假"') do
      cm = @obj.countermodels([['imp', 'A', 'B'], 'B'], 'A')
      !cm.empty? && cm.all? { |m| m['A'] == false && m['B'] == true }
    end
    assert_prop('satisfiable 矛盾为 false') { !@obj.satisfiable?(['A', ['not', 'A']]) }
    assert_prop('satisfiable 一致为 true') { @obj.satisfiable?(['A', ['imp', 'A', 'B']]) }
    assert_prop('countermodels 空 ⟺ entails？') do
      @obj.countermodels(['A', ['imp', 'A', 'B']], 'B').empty? == @obj.entails?(['A', ['imp', 'A', 'B']], 'B')
    end
  end
end