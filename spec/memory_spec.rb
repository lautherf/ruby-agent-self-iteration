# frozen_string_literal: true

require_relative 'spec_helper'

# Memory —— 记忆 = 结构化数据文件 + 简单读写；本体论在代码里（Memory::SCHEMA）。
#
#   memory.yaml：纯数据，两表（turns 原始对话 / lessons 折叠经验）。
#   Memory 类：本体论（kinds / fields / 必填项）→ 契约校验 → 原子落盘（写后读回自检）。
# 不再有"方法体装内容"的把戏：内容就是数据，代码只管它是不是合法、落得稳不稳。
class MemorySpec < Minitest::Test
  include PluginFixture

  def with_memory
    Dir.mktmpdir('mem') do |dir|
      path = File.join(dir, 'memory.yaml')
      yield RubyAgent::Memory.new(path), path
    end
  end

  def test_empty_memory_is_valid_yaml_data
    with_memory do |mem, path|
      assert_empty mem.turns
      assert_empty mem.lessons

      data = YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false)
      assert_equal({ 'turns' => [], 'lessons' => [] }, data, '空记忆 = 两张空表，合法 YAML')
    end
  end

  def test_add_turn_writes_structured_data_not_methods
    with_memory do |mem, path|
      id = mem.add_turn(who: 'user', note: '项目名是 weixin', tags: '项目', kind: 'fact')

      assert_equal 'turn_001', id
      src = File.read(path)
      refute_includes src, 'def turn_001', '内容不得伪装成方法体'
      refute_includes src, '@doc', '不再用注释契约装记忆'

      data = YAML.safe_load(src, permitted_classes: [Symbol], aliases: false)
      first = data['turns'].first
      assert_equal 'turn_001', first['id']
      assert_equal 'user', first['who']
      assert_equal '项目名是 weixin', first['note']
      assert_equal ['项目'], first['tags']
      assert_equal 'fact', first['kind']
      assert first['since']
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

  def test_ontology_rejects_bad_kind_bad_who_empty_note
    with_memory do |mem, _path|
      assert_equal false, mem.add_turn(who: 'user', note: 'x', kind: 'bogus'), '非法 kind 必须拒绝'
      assert_equal false, mem.add_turn(who: 'user', note: '   '), '空 note 必须拒绝'
      assert_equal 0, mem.turns.size, '毒记忆不得落盘'
    end
  end

  def test_ontology_accepts_preference_and_meta_kinds
    with_memory do |mem, _path|
      assert mem.add_turn(who: 'user', note: '喜欢蓝色', kind: 'preference')
      assert mem.add_turn(who: 'ra', note: '我反思了这次迭代', kind: 'meta')
      assert_equal %w[preference meta], mem.turns.map { |t| t[:kind] }
    end
  end

  def test_lessons_channel_independent
    with_memory do |mem, _path|
      mem.add_turn(who: 'user', note: '过程对话', tags: 'chat')
      mem.add_lesson('任务完成：预留 lesson 通道', tags: 'done')

      assert_equal 1, mem.turns.size
      assert_equal 1, mem.lessons.size
      assert_equal ['任务完成：预留 lesson 通道'], mem.lessons.map { |l| l[:note] }
      assert_equal 'lesson', mem.lessons.first[:kind]
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

      assert_equal 3, mem.recall(query: '数学 Ruby', limit: 10).size, '空格分词：命中任意词即召回'
      assert_equal ['数学已经内化', '聊聊 Ruby'],
                   mem.recall(query: '数学 聊聊', limit: 2).map { |t| t[:note] }, '多词查询按最近排序'
    end
  end

  def test_consolidate_folds_old_turns_into_one_lesson
    with_memory do |mem, path|
      6.times { |i| mem.add_turn(who: 'user', note: "闲聊 #{i}", tags: 'chat') }

      summary_id = mem.consolidate!(keep: 2) { |batch| "已压缩 #{batch.size} 条闲聊" }

      assert_equal 'lesson_001', summary_id
      assert_equal ['闲聊 4', '闲聊 5'], mem.turns.map { |t| t[:note] }, '只保留最近 2 条原始对话'
      assert_equal ['已压缩 4 条闲聊'], mem.lessons.map { |l| l[:note] }

      data = YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false)
      assert_equal 2, data['turns'].size
      assert_equal 1, data['lessons'].size, '折叠后必须是合法 YAML 数据'
    end
  end

  def test_consolidate_id_continues_increasing_after_fold
    with_memory do |mem, _path|
      6.times { |i| mem.add_turn(who: 'user', note: "闲聊 #{i}") }
      mem.consolidate!(keep: 2) { |b| "压 #{b.size}" }
      assert_equal 'turn_007', mem.add_turn(who: 'user', note: '折叠后的新对话'),
                   'next_id 取最大编号+1，不回退不重复'
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
      threads = 8.times.map { |i| Thread.new { mem.add_turn(who: 'user', note: "并发 #{i}", tags: 't') } }
      threads.each(&:join)

      mem.load!
      assert_equal 8, mem.turns.size
      assert_equal 8, mem.turns.map { |t| t[:id] }.uniq.size
      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false)
    end
  end

  def test_multiline_note_round_trips_safely
    with_memory do |mem, path|
      mem.add_turn(who: 'ra', note: "第一步：apply_code\n第二步：验证")

      assert_includes mem.turns.first[:note], "\n", '结构化数据天然支持多行'
      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false)
    end
  end
end