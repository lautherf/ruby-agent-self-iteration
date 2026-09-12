# frozen_string_literal: true

require_relative 'spec_helper'

# 回归测试：固化 Doc Demo 的 3 个缺口（详见 docs/doc-demo-review.md）。
#
# 这三条用例在 Demo 的原始实现下全部失败（红）：
#   缺口 1 —— parse 产出字符串键、teach 传符号键 → registry 键分裂
#   缺口 2 —— 注释层零校验 → 非法注释值照样落盘（失败关闭形同虚设）
#   缺口 3 —— merge 缺失 → 旧注释被整体覆盖
# 本仓库的移植实现修复后，三条全部转绿。任何回退都会在此处变红。
class RegressionGapSpec < Minitest::Test
  include PluginFixture

  def build_plugin(path, name = 'math')
    RubyAgent::DocPlugin.new(name, path).load!
  end

  # —— 缺口 1：符号键与字符串键必须落在同一个 registry 槽位 ——
  def test_gap1_symbol_and_string_method_names_share_one_registry_slot
    with_plugin_file do |path|
      plugin = build_plugin(path)

      quietly { plugin.teach(:solve, note: '符号键写入') }

      assert_equal 1, plugin.registry.size, 'registry 不允许出现 :solve / "solve" 两份键'
      assert plugin.registry.key?('solve')
      refute plugin.registry.key?(:solve)
    end
  end

  # —— 缺口 2：注释层非法写入必须被拒绝，且磁盘文件保持原样 ——
  def test_gap2_illegal_doc_value_is_rejected_and_file_unchanged
    with_plugin_file do |path|
      plugin = build_plugin(path)
      before = File.read(path)

      # 注意：payload 必须是**语法合法**的代码，否则会被代码层试编译兜住，
      # 测不出「注释层单独设闸」这件事。
      payload = "合法开头\ndef injected_method; :pwned; end\n# 结束"
      refute quietly { plugin.teach(:solve, syntax: payload) },
             '含换行的注释值必须被拒绝（否则会跳出注释、注入真实代码）'
      assert_equal before, File.read(path), '被拒绝的写入绝不能落盘'
      assert_nil RubyAgent::Doc.parse(path).dig('solve', 'syntax')
      assert_equal '先加后减，求最终答案', RubyAgent::Doc.parse(path).dig('solve', 'role')
    end
  end

  def test_gap2_unknown_doc_key_is_rejected
    with_plugin_file do |path|
      plugin = build_plugin(path)

      refute quietly { plugin.teach(:solve, definitely_not_allowed: 'x') }
      refute RubyAgent::Doc.parse(path).dig('solve', 'definitely_not_allowed')
    end
  end

  # —— 缺口 3：新增注释必须 merge，而不是覆盖旧注释 ——
  def test_gap3_teach_preserves_existing_doc_attrs
    with_plugin_file do |path|
      plugin = build_plugin(path)

      quietly { plugin.teach(:solve, note: '新增说明') }

      expected = { 'role' => '先加后减，求最终答案', 'note' => '新增说明' }
      assert_equal expected, plugin.registry['solve'], '内存中的旧注释必须保留'
      assert_equal expected, RubyAgent::Doc.parse(path)['solve'], '磁盘上的旧注释必须保留'
    end
  end

  # —— 缺口 3 的反面：覆盖同一个 key 时才允许更新 ——
  def test_gap3_same_key_is_updated_not_duplicated
    with_plugin_file do |path|
      plugin = build_plugin(path)

      quietly { plugin.teach(:solve, role: '改写后的角色') }

      assert_equal({ 'role' => '改写后的角色' }, RubyAgent::Doc.parse(path)['solve'])
    end
  end

  # —— 缺口 X：写法名含 ? / !（标点结尾）时，写回必须能定位 def 行 ——
  # 语文内化挖出的坑：rewrite_lines 用 \b 收尾，`is_hanzi?` 的 ? 与后面 ( 之间无词边界，
  # 导致 teach 永远返回 false（定位不到 def 行）。修复改为 空白/左括号 收尾。
  def test_gapX_rewrite_lines_locates_question_mark_method
    with_plugin_file do |path|
      File.open(path, 'w') { |f| f.write("def is_hanzi?(c)\n  c == '中'\nend\n") }
      plugin = build_plugin(path)

      assert quietly { plugin.teach(:is_hanzi?, role: '汉字判断') }
      assert_equal '汉字判断', RubyAgent::Doc.parse(path).fetch('is_hanzi?')['role'],
                   '? 结尾的方法名必须能写回 @doc'
      refute_nil RubyAgent::Doc.parse(path).fetch('is_hanzi?', nil), '解析也要按方法名本身登记'
    end
  end
end
