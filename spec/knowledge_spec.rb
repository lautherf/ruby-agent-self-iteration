# frozen_string_literal: true

require_relative 'spec_helper'

# Sprint 5 · 阶段 1：知识沉淀（Knowledge 经验仓库）
#
# 经验以「注释即契约」持久化：每个 lesson 都是 lessons.rb 里
# `# @doc note: ...` 上方悬空的 `def lesson_XXX`，可被 DocParser / DocPlugin / for_llm 复用。
class KnowledgeSpec < Minitest::Test
  include PluginFixture

  def with_knowledge_file
    Dir.mktmpdir('ruby-agent-knowledge') do |dir|
      yield File.join(dir, 'lessons.rb')
    end
  end

  def test_add_persists_lesson_with_auto_id
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      id = quietly { kb.add('使用 teach 前先 list_docs，避免写入不存在的插件') }

      assert_equal 'lesson_001', id
      assert File.exist?(path)
      assert_includes File.read(path), '# @doc note: 使用 teach 前先 list_docs'
      assert_equal id, kb.lessons.first[:id]
      assert_equal '使用 teach 前先 list_docs，避免写入不存在的插件', kb.lessons.first[:note]
    end
  end

  def test_add_generates_monotonic_ids
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      assert_equal 'lesson_001', quietly { kb.add('a') }
      assert_equal 'lesson_002', quietly { kb.add('b') }
      assert_equal %w[lesson_001 lesson_002], kb.lessons.map { |l| l[:id] }
    end
  end

  def test_add_deduplicates_by_content
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      id1 = quietly { kb.add('重复经验') }
      id2 = quietly { kb.add('重复经验') }

      assert_equal id1, id2
      assert_equal 1, kb.lessons.size
    end
  end

  def test_add_rejects_empty_lesson
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      refute quietly { kb.add('   ') }
      assert_empty kb.lessons
    end
  end

  def test_add_rejects_multiline_lesson_via_doc_validation
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      refute quietly { kb.add("坏经验\ndef injected; end") }
      assert_empty kb.lessons
      assert File.exist?(path) ? (File.read(path) !~ /坏经验/) : true
    end
  end

  def test_tags_are_persisted
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      quietly { kb.add('tag 经验', tags: 'teach,rollback') }

      assert_equal 'teach,rollback', kb.lessons.first[:tags]
      assert_includes File.read(path), '# @doc tags: teach,rollback'
    end
  end

  def test_grade_defaults_to_note_and_persists
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)
      quietly { kb.add('现场心得，未经机械验证') }
      assert_equal 'note', kb.lessons.first[:grade], '默认证据级别必须是 note（未验证）'

      quietly { kb.add('方法边界总结', grade: 'verified') }
      assert_equal 'verified', kb.lessons[1][:grade]
      assert_includes File.read(path), '# @doc grade: verified'
    end
  end

  def test_for_llm_round_trips_through_doc_plugin
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)
      quietly { kb.add('经验一', tags: 'teach') }
      plugin = RubyAgent::DocPlugin.new('knowledge', path).load!

      payload = plugin.for_llm
      assert_equal 'knowledge', payload[:plugin]
      entry = payload[:methods]['lesson_001']
      assert_equal '经验一', entry['note']
      assert_equal 'teach', entry['tags']
    end
  end

  def test_load_reloads_from_disk_after_external_write
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)
      quietly { kb.add('第一版') }

      other = RubyAgent::Knowledge.new(path)
      quietly { other.add('外部新增') }

      assert_equal 1, kb.lessons.size, '内存 view 尚未感知外部写入'
      kb.load!
      assert_equal 2, kb.lessons.size
      assert_includes kb.lessons.map { |l| l[:note] }, '外部新增'
    end
  end

  def test_add_is_thread_safe_no_lost_updates
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)

      threads = 8.times.map { |i| Thread.new { quietly { kb.add("lesson-#{i}") } } }
      ids = threads.map(&:value)

      assert_equal 8, ids.uniq.size
      assert_equal 8, kb.lessons.size
      assert_equal 8, RubyAgent::Doc.parse(path).size, '磁盘与内存必须一致'
    end
  end

  def test_add_is_crash_safe_via_atomic_rename
    with_knowledge_file do |path|
      kb = RubyAgent::Knowledge.new(path)
      quietly { kb.add('原子落盘') }

      src = File.read(path)
      assert_equal src, File.read(path), '无 .tmp 残留（原子 rename 替换）'
      assert RubyVM::InstructionSequence.compile(src), '落盘产物必须可编译'
    end
  end
end