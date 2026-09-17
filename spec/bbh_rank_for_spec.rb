# frozen_string_literal: true

require_relative 'spec_helper'

# bbh 机层 rank_for 契约冻结：选项文字 → [第k, 方位]。
# 回归护栏（真机 250 例长期命中线的底层因为）：
#  ① finished 排位词是绝对序向，独立于 head（不再藏在 when 'first' 里）；
#  ② "Nth-to-last"（从尾端数第 N）必须【先于】纯 "Nth"（从头端数第 N）检查——
#     "finished third-to-last" 含子串 "finished third"，反序会被误判头端。
class BbhRankForSpec < Minitest::Test
  PLUGIN = File.expand_path('../plugins/bbh.rb', __dir__)

  def setup
    @m = Object.new.extend(Module.new.tap { |mod| mod.module_eval(File.read(PLUGIN), PLUGIN, 1) })
  end

  # finished 尾端数（Nth-to-last）——本次修复的核心
  def test_finished_nth_to_last_is_tail_absolute
    assert_equal [3, :t_abs], @m.rank_for('Eli finished third-to-last', 'first')
    assert_equal [2, :t_abs], @m.rank_for('Dan finished second-to-last', 'last')
    assert_equal [1, :t_abs], @m.rank_for('Sue finished first-to-last', 'left')
  end

  # finished 头端/尾端单数
  def test_finished_head_independent
    %w[first top].each { |w| assert_equal [1, :h], @m.rank_for("Joe finished #{w}", 'last') }
    %w[last bottom].each { |w| assert_equal [1, :t], @m.rank_for("Joe finished #{w}", 'first') }
    assert_equal [3, :h], @m.rank_for('Joe finished third', 'last')
  end

  # 物理方位绝对坐标不依赖 head
  def test_physical_absolute_regardless_of_head
    ['left', 'old'].each { |h| assert_equal [1, :abs], @m.rank_for('the red book is the leftmost', h) }
  end
end
