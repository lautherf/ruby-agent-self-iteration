# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 3 阶段 2：Refinements 作用域隔离
# 覆盖三项验收点：作用域隔离 / 多层嵌套 / 清理机制
class RefinementsSpec < Minitest::Test
  # —— 作用域隔离 ——

  def test_refinement_is_invisible_in_global_namespace
    refs = RubyAgent::Refinements.new
    refs.refine(String, :shout) { upcase }

    refute_respond_to 'hi', :shout, '精化不得污染全局 String'
    assert_raises(NoMethodError) { 'hi'.shout }

    assert_equal 'HI', refs.scope_eval("'hi'.shout"), '作用域内应生效'
  end

  def test_two_scopes_with_same_method_do_not_interfere
    up = RubyAgent::Refinements.new
    up.refine(String, :shout) { upcase }

    down = RubyAgent::Refinements.new
    down.refine(String, :shout) { downcase }

    assert_equal 'HI', up.scope_eval("'Hi'.shout")
    assert_equal 'hi', down.scope_eval("'Hi'.shout")
    # 交叉复验：先跑 down 再跑 up，结果仍各自独立
    assert_equal 'hi', down.scope_eval("'Hi'.shout")
    assert_equal 'HI', up.scope_eval("'Hi'.shout")
  end

  # —— 多层嵌套 ——

  def test_inner_scope_shadows_outer_and_outer_survives
    refs = RubyAgent::Refinements.new
    refs.refine(String, :shout) { upcase }

    nested_result = refs.scope_eval(<<~RUBY)
      inner = RubyAgent::Refinements.new
      inner.refine(String, :shout) { downcase }
      inner.scope_eval("'Hi'.shout")
    RUBY

    assert_equal 'hi', nested_result, '内层精化应遮蔽外层同名方法'
    assert_equal 'HI', refs.scope_eval("'Hi'.shout"), '内层退出后外层语义应保持不变'
  end

  def test_multiple_refinements_apply_together_in_one_scope
    refs = RubyAgent::Refinements.new
    refs.refine(String, :shout) { upcase }
    refs.refine(String, :whisper) { |times| downcase * times }

    klass = refs.scope_class(<<~RUBY)
      def loud
        'hi'.shout
      end

      def soft
        'hi'.whisper(2)
      end
    RUBY

    assert_equal 'HI', klass.new.loud
    assert_equal 'hihi', klass.new.soft
  end

  # —— 清理机制 ——

  def test_cleanup_releases_scope_and_is_idempotent
    refs = RubyAgent::Refinements.new
    refs.refine(String, :shout) { upcase }
    refs.scope_eval("'hi'.shout") # 激活作用域

    refute refs.cleaned_up?, '激活后不应处于已清理状态'
    assert refs.refined?(String, :shout)

    refs.cleanup!

    assert refs.cleaned_up?, 'cleanup! 后应处于已清理状态'
    refute refs.refined?(String, :shout), 'cleanup! 应清空注册表'
    assert_empty refs.targets, 'cleanup! 后不应残留目标类型'
    refute_respond_to 'hi', :shout, '清理后全局仍不得被污染'

    refs.cleanup! # 幂等：重复调用不抛异常，状态不变
    assert refs.cleaned_up?
    assert_empty refs.targets
  end

  def test_scope_eval_can_be_reactivated_after_cleanup
    refs = RubyAgent::Refinements.new
    refs.refine(String, :shout) { upcase }
    refs.scope_eval("'hi'.shout")

    refs.cleanup!
    # 清理后重新注册，应能再次投入使用（不残留旧状态）
    refs.refine(String, :shout) { downcase }
    assert_equal 'hi', refs.scope_eval("'Hi'.shout")

    refs.cleanup!
  end

  # —— 边界 ——

  def test_refine_requires_a_block
    refs = RubyAgent::Refinements.new
    assert_raises(ArgumentError) { refs.refine(String, :shout) }
  end
end
