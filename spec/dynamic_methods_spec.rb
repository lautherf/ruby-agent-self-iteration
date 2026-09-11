# frozen_string_literal: true

require_relative 'spec_helper'

class DynamicMethodsSpec < Minitest::Test
  # 构造一个带原始方法的类，混入 DynamicMethodsModule
  def build_klass
    klass = Class.new do
      extend RubyAgent::DynamicMethodsModule

      def original_method
        'original'
      end

      def multi_arg_method(a, b)
        a + b
      end

      def self.class_method
        'class_original'
      end
    end
    klass
  end

  def test_dynamic_method_overrides_and_returns_new_value
    klass = build_klass

    klass.dynamic_method(:original_method) { 'modified' }
    assert_equal 'modified', klass.new.original_method
  end

  def test_dynamic_method_can_take_arguments
    klass = build_klass

    klass.dynamic_method(:multi_arg_method) { |a, b| a * b }
    assert_equal 6, klass.new.multi_arg_method(2, 3)
  end

  def test_rollback_restores_original_behavior
    klass = build_klass

    klass.dynamic_method(:original_method) { 'modified' }
    assert_equal 'modified', klass.new.original_method

    klass.rollback!
    assert_equal 'original', klass.new.original_method
  end

  def test_multiple_dynamic_methods_all_rollback_at_once
    klass = build_klass

    klass.dynamic_method(:original_method) { 'modified_1' }
    klass.dynamic_method(:multi_arg_method) { |a, b| a * b }

    assert_equal 'modified_1', klass.new.original_method
    assert_equal 6, klass.new.multi_arg_method(2, 3)

    klass.rollback!

    assert_equal 'original', klass.new.original_method
    assert_equal 5, klass.new.multi_arg_method(2, 3)
  end

  def test_rollback_is_idempotent
    klass = build_klass

    klass.dynamic_method(:original_method) { 'modified' }
    klass.rollback!
    klass.rollback!  # 多次调用不应报错

    assert_equal 'original', klass.new.original_method
  end

  def test_dynamic_method_on_class_method
    klass = build_klass

    klass.dynamic_class_method(:class_method) { 'class_modified' }
    assert_equal 'class_modified', klass.class_method

    klass.rollback!
    assert_equal 'class_original', klass.class_method
  end
end
