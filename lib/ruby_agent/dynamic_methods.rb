# frozen_string_literal: true

module RubyAgent
  # DynamicMethodsModule —— 给任意 Class 注入动态方法覆盖 + 批量回滚能力。
  #
  # 用法：
  #   klass.extend(DynamicMethodsModule)
  #   klass.dynamic_method(:foo) { 'new' }
  #   klass.rollback!  # 恢复所有动态方法
  module DynamicMethodsModule
    def dynamic_method(name, &block)
      store = @_dynamic_method_store ||= {}
      store[name] = instance_method(name) unless store.key?(name)
      define_method(name, &block)
    end

    def dynamic_class_method(name, &block)
      store = @_dynamic_class_method_store ||= {}
      store[name] = method(name) unless store.key?(name)
      define_singleton_method(name, &block)
    end

    def rollback!
      rollback_instance_methods!
      rollback_class_methods!
    end

    def rollback_instance_methods!
      return unless @_dynamic_method_store

      @_dynamic_method_store.each do |name, original|
        remove_method(name) if method_defined?(name)
        define_method(name, original)
      end
      @_dynamic_method_store.clear
    end

    def rollback_class_methods!
      return unless @_dynamic_class_method_store

      @_dynamic_class_method_store.each do |name, original|
        if singleton_class.method_defined?(name, false)
          singleton_class.class_eval { remove_method(name) }
        end
        define_singleton_method(name, ->(*args, &blk) { original.call(*args, &blk) })
      end
      @_dynamic_class_method_store.clear
    end
  end
end
