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
end
