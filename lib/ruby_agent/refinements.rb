# frozen_string_literal: true

module RubyAgent
  # Refinements —— 词法作用域内的动态方法精化（隔离式修改）。
  #
  # 与 DynamicMethodsModule 的全局猴补丁不同，Refinements 只在
  # `scope_eval` / `scope_class` 打开的隔离作用域内生效；
  # 作用域之外（以及全局）完全无感 —— 这是 Agent 安全试错的基石：
  # 即使精化代码有副作用，也不会污染进程内的全局类型。
  #
  #   refs = RubyAgent::Refinements.new
  #   refs.refine(String, :shout) { upcase }
  #
  #   'hi'.shout                     # => NoMethodError（全局未受影响）
  #   refs.scope_eval("'hi'.shout")  # => "HI"（作用域内生效）
  #
  # === 为什么用 lambda 承载 `using` ===
  # Ruby 规定 `Module#using` 只能出现在**非方法**的词法上下文中
  # （在 `def` 内调用会抛 `RuntimeError: Module#using is not permitted
  # in methods`）；且该限制取决于代码的**词法位置**，与运行时调用栈无关。
  # 因此下面的构造器在类体（非方法）处捕获，实例方法只负责调用它们，
  # 既能动态激活任意精化模块，又不需要把精化模块注册成全局常量。
  class Refinements
    # 在隔离作用域内定义并返回一个匿名类。
    SCOPE_CLASS_BUILDER = lambda do |refinement, source, file, line|
      Class.new do
        using refinement
        class_eval(source, file, line)
      end
    end

    # 在隔离作用域内求值源码，返回最后一个表达式的值。
    SCOPE_EVAL_RUNNER = lambda do |refinement, source, file, line|
      result = nil
      Class.new do
        using refinement
        result = class_eval(source, file, line)
      end
      result
    end

    def initialize
      @refinement = Module.new
      @registry = {}
      @activated = false
    end

    # 注册一条精化规则；返回 self，支持链式调用。
    #
    # @param target_class [Class, Module] 被精化的目标类型
    # @param method_name [Symbol] 被精化的方法名
    # @param impl [Proc] 新实现（块）
    def refine(target_class, method_name, &impl)
      raise ArgumentError, 'refine 需要传入代码块' unless impl

      refinement = @refinement
      refinement.module_eval do
        refine(target_class) { define_method(method_name, &impl) }
      end
      (@registry[target_class] ||= []) << method_name
      self
    end

    # 该 (目标类型, 方法名) 是否已注册精化。
    def refined?(target_class, method_name)
      @registry.fetch(target_class, []).include?(method_name)
    end

    # 已注册精化的目标类型列表。
    def targets
      @registry.keys
    end

    # 在隔离作用域内执行源码字符串，返回最后一个表达式的值。
    # 精化规则仅对该字符串的求值过程可见。
    def scope_eval(source, file: '(refinements)', line: 1)
      @activated = true
      SCOPE_EVAL_RUNNER.call(@refinement, source, file, line)
    end

    # 在隔离作用域内定义并返回一个匿名类；其实例方法可见精化规则。
    def scope_class(source, file: '(refinements)', line: 1)
      @activated = true
      SCOPE_CLASS_BUILDER.call(@refinement, source, file, line)
    end

    # 注销精化：丢弃已积累的精化模块、清空注册表。
    # 幂等，可重复调用；清理后可重新 refine 再次投入使用。
    def cleanup!
      @refinement = Module.new
      @registry.clear
      @activated = false
      self
    end

    # 是否已清理（尚未激活或已注销均为 true）。
    def cleaned_up?
      !@activated
    end
  end
end
