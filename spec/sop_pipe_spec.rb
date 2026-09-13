# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/ruby_agent/sop_pipe'

# 解剖×机验互锁判分器规范 —— 三锁裁决不掺水。
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
    stage2 = { 'premises' => [['imp', 'A', 'B'], 'B'], 'conclusion' => 'A', 'claimed' => 'not_entailed' }
    j = SopPipe.judge(stage1, stage2, '三段论滥用')
    assert j.pass
    assert j.fault_hit && j.verify_hit && j.claimed_aligned
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
end