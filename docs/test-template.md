# 初始化测试文件模板

```ruby
# frozen_string_literal: true

require_relative 'spec_helper'

class ExampleClassSpec < Minitest::Test
  def setup
    @instance = RubyAgent::ExampleClass.new
  end

  def test_example_method_returns_expected_value
    assert_equal :expected_value, @instance.example_method
  end

  def test_example_method_handles_edge_case
    @instance.example_method # 不抛异常即通过
  end

  def test_example_method_raises_on_bad_input
    assert_raises(ArgumentError) { @instance.example_method(:bad) }
  end
end
```
