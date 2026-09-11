# frozen_string_literal: true

# 测试驱动开发（TDD）工作流规范
#
# 遵循红-绿-重构循环：
#
# 1. 红（Red）
#    - 先写测试，确认测试失败
#    - 测试描述期望的行为
#    - 使用断言式 API（assertion-based）
#
# 2. 绿（Green）
#    - 编写最小可运行代码
#    - 不追求完美，只追求通过测试
#    - 测试应该立即通过
#
# 3. 重构（Refactor）
#    - 清理代码，消除重复
#    - 提取公共逻辑
#    - 改进命名
#    - 再次运行测试确认无回归
#
# 关键原则：
# - 每个新功能先写测试
# - 测试失败时再写实现
# - 测试通过后立即重构
# - 保持测试覆盖率 > 80%
#
# 命名规范：
# - spec/model_name_spec.rb
# - class ModelNameSpec < Minitest::Test 块
# - 使用 test_describes_expected_behavior 方法名
