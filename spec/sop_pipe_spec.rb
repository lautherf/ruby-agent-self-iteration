# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/ruby_agent/sop_pipe'

# 解剖×机验互锁判分器规范 —— 四锁裁决不掺水。
class SopPipeSpec < Minitest::Test
  def test_expect_dict_maps_faults_to_machine_verdicts
    assert_equal :not_entailed, SopPipe::EXPECTED['因果混淆']
    assert_equal :not_entailed, SopPipe::EXPECTED['量词误用']
    assert_equal :not_entailed, SopPipe::EXPECTED['三段论滥用']
    assert_equal :entailed,     SopPipe::EXPECTED[SopPipe::CORRECT]
  end

  def test_exempt_semantic_faults_expect_nil
    SopPipe::EXEMPT_TYPES.each do |f|
      assert_nil SopPipe::EXPECTED[f], "#{f} 应为语义豁免类"
      refute SopPipe::EXEMPT_TYPES.include?('因果混淆')
    end
  end

  def test_pass_when_all_three_locks_hold_for_fallacy
    stage1 = { 'fault_type' => '三段论滥用', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A',
               'claimed' => 'not_entailed', 'suspects' => ['A'] }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    assert j.pass
    assert j.fault_hit && j.verify_hit && j.claimed_aligned
  end

  def test_multi_tag_hits_when_expected_subset_match
    # 复合错位"一词多义×组块"：只要期望 ∈ 标签集即可 PASS（评审学调整，不注水）
    stage1 = { 'fault_type' => '组块歧义,一词多义' }
    j = SopPipe.judge(stage1, nil, '组块歧义')
    assert j.pass, "多标签含期望应 PASS：#{j.diag}"
    assert j.fault_hit
  end

  def test_multi_tag_still_fails_without_expected
    stage1 = { 'fault_type' => '一词多义,组块歧义' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A', 'claimed' => 'not_entailed' }
    j = SopPipe.judge(stage1, stage2, '因果混淆')
    refute j.pass
    refute j.fault_hit
  end

  def test_multi_tag_zero_tolerance_for_oob_words
    # 白名单外自创词哪怕绑了合法标签也必须红（防"自创词+挡箭牌"作弊）
    stage1 = { 'fault_type' => '三段论滥用,没见过的新类型' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A', 'claimed' => 'not_entailed' }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    refute j.pass
    refute j.fault_hit
  end

  def test_fail_when_fault_tag_skips_whitelist
    stage1 = { 'fault_type' => '自创类型词', 'hidden_premise' => '…' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A', 'claimed' => 'not_entailed' }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    refute j.pass
    refute j.fault_hit
  end

  def test_fail_when_machine_verdict_mismatch
    # 解剖说三段论滥用（期望 not_entailed），但 LLM 形式化成了 modus ponens（机器判 entailed）
    stage1 = { 'fault_type' => '三段论滥用' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'A'], 'conclusion' => 'B', 'claimed' => 'entailed' }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    refute j.pass
    refute j.verify_hit
  end

  def test_fail_when_claimed_contradicts_machine
    # 机器明明可证（A→B, A ⊢ B），LLM 却自报 not_entailed → 与机器矛盾
    stage1 = { 'fault_type' => SopPipe::CORRECT }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'A'], 'conclusion' => 'B', 'claimed' => 'not_entailed' }
    j = SopPipe.judge(stage1, stage2, SopPipe::CORRECT)
    refute j.pass
    refute j.claimed_aligned
  end

  def test_correct_reasoning_needs_entailed_proof
    stage1 = { 'fault_type' => SopPipe::CORRECT }
    stage2 = { 'premises' => [['imp', 'M', 'D'], 'M'], 'conclusion' => 'D', 'claimed' => 'entailed' }
    j = SopPipe.judge(stage1, stage2, SopPipe::CORRECT)
    assert j.pass, "正确推理应给 entailed 证明：#{(j.diag || '')}"
  end

  def test_correct_reasoning_fails_without_proof
    # 正确推理必须有真正的前提：只有 M（是人）推不出 M→D（会死）——这是缺前提的不可证例子
    stage1 = { 'fault_type' => SopPipe::CORRECT }
    stage2 = { 'premises' => ['M'], 'conclusion' => ['imp', 'M', 'D'], 'claimed' => 'entailed' }
    j = SopPipe.judge(stage1, stage2, SopPipe::CORRECT)
    refute j.pass
    refute j.verify_hit
  end

  def test_exempt_semantic_applies_anatomy_lock_only
    stage1 = { 'fault_type' => '一词多义', 'hidden_premise' => '小人双义' }
    j = SopPipe.judge(stage1, nil, '一词多义')
    assert j.pass, 'exempt 类只斩解剖锁，应 PASS'
    assert j.exempt
  end

  def test_exempt_still_fails_on_wrong_tag
    stage1 = { 'fault_type' => '组块歧义', 'hidden_premise' => '…' }
    j = SopPipe.judge(stage1, nil, '一词多义')
    refute j.pass
    refute j.fault_hit
  end

  def test_machine_crash_is_fail
    stage1 = { 'fault_type' => '因果混淆' }
    stage2 = { 'premises' => [['bogus', 'A', 'B']], 'conclusion' => 'A', 'claimed' => 'x' }
    j = SopPipe.judge(stage1, stage2, '因果混淆')
    refute j.pass
    refute j.verify_hit
  end

  # ── SopLock·隔离锁（Sop-NL-01∘02 第4锁·翻译作弊零容忍）──
  # 解剖锁+机验锁是双向背书，但这套背书在'翻译作弊'面前会互相递刀子——
  # 模型把受审槽（谚语律/因果律/量词互换...）声明成合法 imp 前提写进 premises，
  # 机验验 entailed、解剖也说中了，两把锁齐齐给被告发无罪证书。这正是本卷最高危缺口。
  # 隔离锁要求：谬误类里受审槽变量不得混进 premises 这座合法前提台（翻译作弊直接斩）；
  # 正确推理类本来就该 entailed，无受审槽可言，不斩。语义豁免类已豁免，不斩。

  def test_translation_cheat_isolated_by_suspect_lock
    # 受审槽 I（"冰激凌销量高")被写成确定性 imp 前提摆上合法前提台 → 隔离锁照斩；
    # 机验锁此时也会因 entailed ≠ 期望 not_entailed 跟着红——双锁合璧，翻译作弊无处可躲
    stage1 = { 'fault_type' => '因果混淆', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => [["imp", "I", "D"], "I"], 'conclusion' => "D",
               'claimed' => 'entailed', 'suspects' => ["I"] }
    j = SopPipe.judge(stage1, stage2, '因果混淆')
    refute j.pass, "受审槽 I 混进 premises，隔离锁应斩：#{(j.diag || '')}"
    refute j.verify_hit # 机验锁因 entailed 与期望 not_entailed 不符，随隔离一起红
  end

  def test_suspect_isolated_from_premises_passes
    # 受审槽 A 只在 suspects 自报（抱上被告席）、B 坐合法 premises 台但不进 suspects
    # → 两槽各就各位、绝无交集 → 隔离锁绿；机验仍应 not_entailed（正确保住谬误本色）
    stage1 = { 'fault_type' => '三段论滥用', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => ['B'], 'conclusion' => 'A',
               'claimed' => 'not_entailed', 'suspects' => ['A'] }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    assert j.pass
    assert j.isolated
  end

  def test_compound_premise_containing_suspect_not_smuggled
    # 隔离锁判"顶层完整前提"而非 flatten 盲扫：复合前提 imp(A,B) 里含受审槽 A 是
    # 前提的天然构成（三段论前提当然要谈推论项），不得误杀——否则所有 honest 形式化全红。
    # 翻译作弊的实锤形态是受审槽单独成一格顶层前提（"A" 裸变量顶上），那才是斩点。
    stage1 = { 'fault_type' => '三段论滥用', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A',
               'claimed' => 'not_entailed', 'suspects' => ['A'] }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    assert j.pass, "复合前提含受审槽成分=合法构成，隔离锁应绿：#{(j.diag || '')}"
    assert j.isolated
    assert j.verify_hit # 机验后门继续背书：A→B, B ⊢ A 有反例（A=F,B=T），not_entailed 属实
  end

  def test_diag_pins_translation_cheat_source
    # FAIL 归因：diag 必须指名走私的受审槽，否则真机 14/20 的 FAIL 无法定位是人话翻错
    # 还是翻译作弊——机验兜底后隔离锁是唯一能说出"谁在作弊"的一锁
    stage1 = { 'fault_type' => '因果混淆', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => ['I'], 'conclusion' => 'D',
               'claimed' => 'not_entailed', 'suspects' => ['I'] }
    j = SopPipe.judge(stage1, stage2, '因果混淆')
    refute j.pass
    assert_includes j.diag, '走私'
    assert_includes j.diag, 'I'
  end

  def test_suspect_smuggled_into_premises_red
    # 受审槽 B 同时坐 suspects 自报又混进 premises（把被告请上原告席）= 翻译作弊实锤
    # —— lesson_017 评审学正章：机验再 not_entailed 也斩（零赦，这正是隔离锁存在的理由）
    stage1 = { 'fault_type' => '三段论滥用', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => ['B'], 'conclusion' => 'A',
               'claimed' => 'not_entailed', 'suspects' => ['B'] }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    refute j.pass, "受审槽 B 混进 premises=走私实锤，隔离锁必斩：#{(j.diag || '')}"
    refute j.isolated
  end

  def test_suspect_empty_self_report_is_hidden_defendant
    # 谬误类交付 suspects 空自报 = 把被告藏进 vault 一根不发审 → 隔离锁零赦红
    stage1 = { 'fault_type' => '三段论滥用', 'hidden_premise' => '…', 'reason' => '…' }
    stage2 = { 'premises' => ['B'], 'conclusion' => 'A',
               'claimed' => 'not_entailed', 'suspects' => [] }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    refute j.pass, "空自报=藏被告，隔离锁应收红：#{(j.diag || '')}"
    refute j.isolated
    assert_includes j.diag, '零自报'
  end

  def test_correct_reasoning_immune_to_suspect_lock
    # 正确推理无受审槽，即使自报 suspects 也不隔离；必须 entailed
    stage1 = { 'fault_type' => SopPipe::CORRECT }
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'A'], 'conclusion' => 'B',
               'claimed' => 'entailed', 'suspects' => [] }
    j = SopPipe.judge(stage1, stage2, SopPipe::CORRECT)
    assert j.pass
  end

  def test_exempt_semantics_pass_suspect_lock_by_default
    stage1 = { 'fault_type' => '一词多义', 'hidden_premise' => '…' }
    j = SopPipe.judge(stage1, nil, '一词多义')
    assert j.pass, "语义豁免类不受隔离锁约束：#{(j.diag || '')}"
  end
end