# frozen_string_literal: true

require_relative 'prop_solver'

# SopPipe —— 解剖×机验互锁判分器（SOP-NL-01 ∘ SOP-NL-02 的评审台）。
#
# 设计初衷（"你说得对"之后实现的方向）：两条 SOP 此前是平行独立 harness——
#   解剖（SOP-NL-01）识别 fault_type，开放文本判分靠老师；
#   机验（SOP-NL-02）形式化为 AST，纯机器判分。
# 本模块把两层串成一条管线并让它们**互相背书**：
#   解剖说"这是量词误用"，机验就必须给出反例模型（not_entailed）；
#   解剖说"这是正确推理"，机验就必须给出无反例证明（entailed）。
# 脱钩即红——这就是"因果混淆标签"第一次获得机器反例背书。
#
# 边界（诚实分舱）：
#   · provable 类：布尔可还原的谬误（因果/组成/量词/三段论/谚语/幸存者）→ 四锁全判
#   · exempt  类：语义/词义跳跃（一词多义/组块/互补分割/循环/相对时间/名实）→ 布尔层还原失真，
#                只判解剖锁（白名单命中），机验锁豁免并在成绩单显式标注 EXEMPT。
module SopPipe
  FAULT_TYPES = %w[
    互补分割误读 相对时间误用 幸存者偏差 定义循环 概率与组成混淆 组块歧义
    一词多义 谚语全称滥用 名实错位 量词误用 三段论滥用 因果混淆
  ].freeze

  CORRECT = '正确推理'
  ALL_TYPES = FAULT_TYPES + [CORRECT]

  # 布尔层会还原失真的语义类：豁免机验
  EXEMPT_TYPES = %w[互补分割误读 相对时间误用 定义循环 组块歧义 一词多义 名实错位].freeze

  # fault_type → 机验期望（nil=豁免机验）
  EXPECTED = begin
    m = FAULT_TYPES.each_with_object({}) do |f, h|
      h[f] = EXEMPT_TYPES.include?(f) ? nil : :not_entailed
    end
    m[CORRECT] = :entailed
    m.freeze
  end

  Judge = Struct.new(:pass, :fault_hit, :verify_hit, :claimed_aligned, :exempt, :isolated, :diag, keyword_init: true)

  # fault_type 字段可含逗号/顿号/斜杠分隔的多标签；解析出白名单内 actual 与名单外 oob。
  # oob 一旦非空即解剖锁必红（零容忍自创词）。
  def self.parse_tags(stage1)
    return { actual: [], oob: [] } unless stage1.is_a?(Hash)

    tags = stage1['fault_type'].to_s.split(/[,，、\/]/).map(&:strip).reject(&:empty?)
    { actual: tags.select { |t| ALL_TYPES.include?(t) }, oob: tags.reject { |t| ALL_TYPES.include?(t) } }
  end

  # judge(stage1, stage2, fault) → Judge
  #   stage1 解剖产物：{ 'fault_type' => '…' 或 '…','…'（多标签逗号分隔）, 'hidden_premise' =>, 'reason' => } 或 nil
  #   stage2 机验产物：{ 'premises' =>, 'conclusion' =>, 'claimed' => } 或 nil（exempt 时可为 nil）
  #   fault  = 该题期望的 fault_type（∈ ALL_TYPES）
  #
  # 多标签开放：句子的错位常常是复合的（如"一词多义×组块"），解剖锁改成
  # "期望 fault ∉ 模型给的白名单标签集"（交集判缺，不是全等）——依旧零容忍白名单外词，
  # 但不再因两个合法标签都沾边就误杀。这是评审学调整，不是放水。
  def self.judge(stage1, stage2, fault)
    expected = EXPECTED[fault.to_s]
    raise ArgumentError, "未知 fault_type: #{fault.inspect}" unless ALL_TYPES.include?(fault.to_s)

    exempt = expected.nil?
    parsed = parse_tags(stage1)
    fault_hit = parsed[:actual].include?(fault.to_s) && parsed[:oob].empty? && !parsed[:actual].empty?

    unless exempt
      raise ArgumentError, "provable 类 #{fault} 必须提供 stage2" if stage2.nil?

      begin
        premises   = stage2['premises'] || []
        conclusion = stage2['conclusion']
        claimed    = stage2['claimed'].to_s
        suspects   = Array(stage2['suspects']).map(&:to_s).reject(&:empty?)
        machine    = (conclusion && !premises.empty?) ? PropSolver.verify(premises, conclusion)[:entailed] : nil
      rescue StandardError => e
        machine = :crash
      end
      verify_ok = machine == (expected == :entailed)
      claimed_ok = claimed == (machine == :crash ? nil : (machine ? 'entailed' : 'not_entailed'))

      # 受审槽隔离锁（SopLock·执法时机修订版·lesson_018 事实检证回归）——机验产物对谬误类
      # 必须交付 suspects 白名单自报（把被告一个个抱上被告席），且受审槽不得作为
      # **顶层完整前提**摆上 premises 合法前提台。判定用顶层 include? 而非 flatten 盲扫：
      # 合法复合前提 A→B 里含受审槽 A 是前提天然构成；翻译作弊的实锤形态是受审槽独自成格。
      #
      # 执法时机（真机事实检证 Y2026-09-15 修订）：隔离锁只在 **machine == :entailed** 时开审——
      # 唯此状态才存在"受审槽把机器带偏"的作弊疑云：
      #   · 机器判 not_entailed → 无受审槽把机器带偏 → 恒绿。受审槽变量常与句子显式事实
      #     天然重合（rain："今天路滑"S 就该独立成格；failure："他失败很多次"F 同理），
      #     此前独立式"受审槽不上顶层台"把这两例 honest 形式化误斩成 FAIL（真机 7 FAIL 占 2）。
      #   · 机器判 entailed → 开审：suspects 空=藏被告红；受审槽顶层走私红——双锁合璧定罪，
      #     与机验锁互为第二锚点（harvest 谚语律进前提）；复合前提内部（imp/and 内层）不放隔离
      #     锁（icecream 形态），那是机验锁的地盘：机器反例仍会 say not_entailed 兜底。
      #   · 正确推理(:entailed)/豁免(nil) 不碰受审槽 → 恒绿。
      isolated = expected == :entailed || expected.nil? ||
                 machine != true ||
                 suspects.any? && (suspects & Array(premises)).empty?
    else
      verify_ok = true
      claimed_ok = true
      isolated = true
    end

    pass = fault_hit && verify_ok && claimed_ok && isolated
    Judge.new(
      pass: pass, fault_hit: fault_hit, verify_hit: verify_ok, claimed_aligned: claimed_ok,
      exempt: exempt, isolated: isolated,
      diag: diag_of(fault_hit, verify_ok, claimed_ok, exempt, isolated, stage1, stage2, expected)
    )
  end

  def self.diag_of(fault_hit, verify_ok, claimed_ok, exempt, isolated, stage1, stage2, expected)
    parts = []
    parsed = parse_tags(stage1)
    if stage1
      label = parsed[:actual].inspect
      label += " + 名单外词#{parsed[:oob].inspect}" unless parsed[:oob].empty?
      parts << "解剖标签 #{label}#{fault_hit ? '' : ' ← 缺期望命中'}"
    end
    unless exempt
      machine = (stage2 && stage2['conclusion']) ? begin
        PropSolver.verify(stage2['premises'] || [], stage2['conclusion'])[:entailed]
      rescue StandardError
        :crash
      end : nil
      parts << "机器推演=#{machine == :crash ? 'crash' : (machine ? 'entailed' : 'not_entailed')}（期望 #{expected}）#{verify_ok ? '' : ' ← 不符'}"
      if stage2.is_a?(Hash)
        parts << "自报=#{stage2['claimed'].to_s.inspect}#{claimed_ok ? '' : ' ← 与机器不符'}"
      end
      unless isolated
        suspects = Array(stage2 && stage2['suspects']).map(&:to_s).reject(&:empty?)
        if suspects.empty?
          parts << '隔离锁红：受审槽零自报（藏被告不发审）'
        else
          smuggled = suspects & Array(stage2['premises'])
          parts << "隔离锁红：受审槽 #{smuggled.inspect} 走私上合法前提台"
        end
      end
    else
      parts << 'EXEMPT：语义类仅斩解剖锁'
    end
    parts.join('；')
  end
end