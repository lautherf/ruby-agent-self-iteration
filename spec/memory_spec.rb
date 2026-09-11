# frozen_string_literal: true

require_relative 'spec_helper'

# Memory —— 「记忆即代码」（Sprint 7 设计契约）。
#
# 愿景：记忆不是数据库里的行，而是 Ruby 文件里的存根方法与 `# @doc` 注释契约，
# 与 lessons 同构、可编译、可回滚、可 git diff、可遗忘（删存根 / 折叠成 lesson）。
# 双通道：turn_XXX = 原始对话流水；lesson_XXX = 折叠后的压缩经验。
class MemorySpec < Minitest::Test
  include PluginFixture

  def with_memory
    Dir.mktmpdir('mem') do |dir|
      path = File.join(dir, 'memory.rb')
      yield RubyAgent::Memory.new(path), path
    end
  end

  def test_empty_memory_is_header_code_that_compiles
    with_memory do |mem, path|
      assert_empty mem.turns
      assert_empty mem.lessons
      assert RubyVM::InstructionSequence.compile(File.read(path)), '空记忆也必须是一段可编译代码'
    end
  end

  def test_add_turn_writes_note_as_real_method_body
    with_memory do |mem, path|
      id = mem.add_turn(who: 'user', note: '帮我把小学数学内化进你自己', tags: 'math')

      assert_equal 'turn_001', id
      src = File.read(path)
      assert_includes src, '# @doc who: user'
      assert_includes src, "# @doc since:"
      assert_includes src, '# @doc tags: math'
      refute_includes src, '# @doc note:', 'note 是方法体，不得在注释里重复一份'
      assert_includes src, "def turn_001\n  \"帮我把小学数学内化进你自己\"\nend"
      assert RubyVM::InstructionSequence.compile(src)
    end
  end

  def test_memory_file_is_evaluable_and_returns_payload
    with_memory do |mem, path|
      mem.add_turn(who: 'user', note: '项目名是 weixin', tags: 'math')
      mem.add_lesson('折叠了 3 条旧对话')

      bodies = RubyAgent::Memory.eval_bodies(path)
      assert_equal '项目名是 weixin', bodies['turn_001'], '记忆=代码：求值方法体就能读回记忆'
      assert_equal '折叠了 3 条旧对话', bodies['lesson_001']
    end
  end

  def test_multiline_note_round_trips_safely
    with_memory do |mem, path|
      id = mem.add_turn(who: 'ra', note: "第一步：apply_code\n第二步：验证")

      assert_equal 'turn_001', id
      assert_includes mem.turns.first[:note], "\n", '多行内容也该原样读回'
      assert RubyVM::InstructionSequence.compile(File.read(path))
      src = File.read(path)
      refute_includes src, "# @doc note:", 'note 不应进注释层'
      assert_equal 1, src.lines.count { |l| l.include?('第一步') }, 'inspect 转义后仍是一行物理代码'
    end
  end

  def test_turns_roundtrip_in_file_order
    with_memory do |mem, _path|
      mem.add_turn(who: 'user', note: '第一句', tags: 'a')
      mem.add_turn(who: 'ra', note: '第二句', tags: 'b')

      turns = mem.turns
      assert_equal %w[turn_001 turn_002], turns.map { |t| t[:id] }
      assert_equal ['user', 'ra'], turns.map { |t| t[:who] }
      assert_equal ['第一句', '第二句'], turns.map { |t| t[:note] }
    end
  end

  def test_recall_returns_newest_first_and_filters_by_query
    with_memory do |mem, _path|
      mem.add_turn(who: 'user', note: '讲讲数学', tags: 'math')
      mem.add_turn(who: 'user', note: '聊聊 Ruby', tags: 'code')
      mem.add_turn(who: 'ra', note: '数学已经内化', tags: 'math')

      assert_equal 3, mem.recall(limit: 10).size
      assert_equal ['数学已经内化', '聊聊 Ruby', '讲讲数学'],
                   mem.recall(limit: 10).map { |t| t[:note] }, '最新在前'
      assert_equal 2, mem.recall(query: '数学', limit: 10).size
      assert_equal 1, mem.recall(query: '聊聊 Ruby', limit: 10).size

      multi = mem.recall(query: '数学 Ruby', limit: 10)
      assert_equal 3, multi.size, '空格分词：命中任意词即召回'
      assert_equal ['数学已经内化', '聊聊 Ruby'],
                   mem.recall(query: '数学 聊聊', limit: 2).map { |t| t[:note] }, '多词查询按最近排序'
    end
  end

  def test_lessons_channel_independent
    with_memory do |mem, _path|
      mem.add_turn(who: 'user', note: '过程对话', tags: 'chat')
      mem.add_lesson('任务完成：预留 lesson 通道', tags: 'done')

      assert_equal 1, mem.turns.size
      assert_equal 1, mem.lessons.size
      assert_equal ['任务完成：预留 lesson 通道'], mem.lessons.map { |l| l[:note] }
    end
  end

  def test_consolidate_folds_old_turns_into_one_lesson
    with_memory do |mem, path|
      6.times { |i| mem.add_turn(who: 'user', note: "闲聊 #{i}", tags: 'chat') }

      summary_id = mem.consolidate!(keep: 2) { |batch| "已压缩 #{batch.size} 条闲聊" }

      assert_equal 'lesson_001', summary_id
      assert_equal ['闲聊 4', '闲聊 5'], mem.turns.map { |t| t[:note] }, '只保留最近 2 条原始对话'
      assert_equal ['已压缩 4 条闲聊'], mem.lessons.map { |l| l[:note] }
      assert RubyVM::InstructionSequence.compile(File.read(path)), '折叠必须是合法代码'
    end
  end

  def test_consolidate_noop_below_window
    with_memory do |mem, _path|
      mem.add_turn(who: 'user', note: 'hi')

      assert_equal false, mem.consolidate!(keep: 5) { |_b| 'x' }
      assert_equal 1, mem.turns.size
    end
  end

  def test_consolidate_rejects_empty_summary
    with_memory do |mem, _path|
      6.times { |i| mem.add_turn(who: 'user', note: "n #{i}") }

      assert_equal false, mem.consolidate!(keep: 1) { |_b| '   ' }
      assert_equal 6, mem.turns.size, '空摘要不得破坏记忆'
    end
  end

  def test_concurrent_turns_never_lose_updates
    with_memory do |mem, path|
      threads = 8.times.map do |i|
        Thread.new { mem.add_turn(who: 'user', note: "并发 #{i}", tags: 't') }
      end
      threads.each(&:join)

      mem.load!
      assert_equal 8, mem.turns.size
      assert_equal 8, mem.turns.map { |t| t[:id] }.uniq.size
      assert RubyVM::InstructionSequence.compile(File.read(path))
    end
  end
end