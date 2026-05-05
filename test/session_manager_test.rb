# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"

class SessionManagerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @manager = Kreator::SessionManager.new(session_dir: @dir)
    @cwd = Dir.pwd
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_create_writes_header_and_appends_messages
    session = @manager.create(cwd: @cwd)

    session.append_message(Kreator::Message.user("hello"))
    session.append_message(Kreator::Message.assistant("hi"))

    lines = File.readlines(session.path)
    header = JSON.parse(lines.first)

    assert_equal "session_header", header.fetch("type")
    assert_equal 1, header.fetch("version")
    assert_equal @cwd, header.fetch("cwd")
    assert_equal %w[user assistant], session.messages.map(&:role)
    assert_equal "hi", session.messages.last.content
  end

  def test_open_loads_session_by_path
    session = @manager.create(cwd: @cwd)
    session.append_message(Kreator::Message.user("hello"))

    opened = @manager.open(path: session.path)

    assert_equal session.id, opened.id
    assert_equal ["hello"], opened.messages.map(&:content)
  end

  def test_open_loads_session_by_id
    session = @manager.create(cwd: @cwd)

    opened = @manager.open(path: session.id)

    assert_equal session.path, opened.path
  end

  def test_continue_recent_uses_newest_session_for_cwd
    older = @manager.create(cwd: @cwd)
    sleep 0.001
    newer = @manager.create(cwd: @cwd)

    continued = @manager.continue_recent(cwd: @cwd)

    refute_equal older.id, continued.id
    assert_equal newer.id, continued.id
  end

  def test_compaction_is_append_only_and_returns_compacted_context
    session = @manager.create(cwd: @cwd)
    12.times { |index| session.append_message(Kreator::Message.user("message #{index}")) }

    compacted = session.compact!(keep_last: 3)

    assert_equal "system", compacted.first.role
    assert_includes compacted.first.content, "Earlier conversation was compacted"
    assert_equal 4, compacted.length
    assert_equal 1, session.compaction_entries.length
    assert_equal 12, session.messages.length
    assert_equal %w[system user user user], session.compacted_messages.map(&:role)
  end

  def test_fork_creates_child_session_from_entry
    session = @manager.create(cwd: @cwd)
    session.append_message(Kreator::Message.user("first"))
    session.append_message(Kreator::Message.assistant("second"))
    session.append_message(Kreator::Message.user("third"))

    forked = @manager.fork(path: session.path, entry_index: 1)

    assert_equal session.id, forked.parent_id
    assert_equal %w[first second], forked.messages.map(&:content)
    assert_equal([forked.id], @manager.branches(parent_id: session.id).map { |summary| summary.fetch("id") })
  end

  def test_labels_search_and_transcript_export
    session = @manager.create(cwd: @cwd)
    session.append_label("review")
    session.append_message(Kreator::Message.user("find this request"))
    session.append_message(Kreator::Message.assistant("done"))

    matches = @manager.search(query: "find this", cwd: @cwd)
    markdown = @manager.export(path: session.path, format: "markdown")
    json = JSON.parse(@manager.export(path: session.path, format: "json"))

    assert_equal([session.id], matches.map { |summary| summary.fetch("id") })
    assert_equal ["review"], matches.first.fetch("labels")
    assert_includes markdown, "### user"
    assert_equal session.id, json.fetch("header").fetch("id")
  end

  def test_cleanup_empty_sessions_only_deletes_empty_sessions
    empty = @manager.create(cwd: @cwd)
    kept = @manager.create(cwd: @cwd)
    kept.append_message(Kreator::Message.user("keep"))

    deleted = @manager.cleanup(cwd: @cwd, empty: true)

    assert_equal([empty.id], deleted.map { |summary| summary.fetch("id") })
    refute File.exist?(empty.path)
    assert_path_exists kept.path
  end
end
