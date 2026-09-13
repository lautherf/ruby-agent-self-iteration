# frozen_string_literal: true

require_relative 'spec_helper'

# 测评模式（mode: :exam）—— 把"考场不许写"从 harness 的临时 hack 变成框架内建纪律。
#
# 动机：弱智吧考试时 LLM 反复 apply_code/verify/learn（想当场写库、验算、沉淀），
#       甚至残留了未经验证的 def answer 方法。这些本该由框架制度挡掉，而非靠我逐个 BAN。
# install：AgentLoop.new(..., mode: :exam) 之后写工具（apply_code/verify/teach/learn）与
#          whoami 一律返回拦截文案；只读检索（read_docs/read_code/library/list_docs）照常可用。
# 默认 mode: :normal 行为完全不变（0 行为回归）。
class ExamModeSpec < Minitest::Test
  include PluginFixture

  def build_exam_agent
    hub = RubyAgent::DocHub.new
    RubyAgent.mount_ra!(hub)
    knowledge_tmp = RubyAgent::Knowledge.new(File.join(Dir.mktmpdir, '_lessons.rb'))
    RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']),
                             knowledge: knowledge_tmp, writable_plugins: ['ra'], mode: :exam)
  end

  def test_exam_default_normal_keeps_write_tools_registered
    hub = RubyAgent::DocHub.new
    RubyAgent.mount_ra!(hub)
    knowledge_tmp = RubyAgent::Knowledge.new(File.join(Dir.mktmpdir, '_lessons.rb'))
    agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']),
                                     knowledge: knowledge_tmp)

    assert_includes agent.tools.keys, 'apply_code'
    assert_includes agent.tools.keys, 'verify'
    assert_includes agent.tools.keys, 'teach'
    assert_includes agent.tools.keys, 'learn'
    assert_includes agent.tools.keys, 'whoami'
  end

  def test_exam_blocks_write_tools
    agent = build_exam_agent

    %w[apply_code verify teach learn whoami].each do |t|
      text = agent.invoke_tool(t, {})
      assert_includes text, '测评模式', "exam 应拦截 #{t}，实际返回：#{text}"
    end
  end

  def test_exam_keeps_read_tools_available
    agent = build_exam_agent

    assert agent.tools.key?('read_docs')
    assert agent.tools.key?('read_code')
    assert agent.tools.key?('library')
    assert agent.tools.key?('list_docs')
    refute_includes agent.invoke_tool('list_docs', {}).to_s, '测评模式'
  end

  def test_exam_prevents_pollution_of_plugin_file
    Dir.mktmpdir do |dir|
      plugin_path = File.join(dir, 'math.rb')
      File.write(plugin_path, "# @doc role: 加法\n# @doc example: add(1,2)\ndef add(a, b)\nend\n")
      knowledge_tmp = RubyAgent::Knowledge.new(File.join(dir, 'lessons.rb'))

      hub = RubyAgent::DocHub.new
      hub.mount(RubyAgent::DocPlugin.new('math', plugin_path).load!)
      agent = RubyAgent::AgentLoop.new(hub: hub, llm: RubyAgent::MockLLM.new(['Final Answer: ok']),
                                       knowledge: knowledge_tmp, mode: :exam)

      agent.invoke_tool('apply_code', { 'plugin' => 'math', 'method' => 'add',
                                        'code' => 'def add(a, b); a + b; end' })

      refute_includes File.read(plugin_path), 'a + b', 'exam 模式下 apply_code 不得落盘'
    end
  end
end