# frozen_string_literal: true
#
# Local Minitest command:
#   ruby -Ilib -Itest test/test_rake_fingerprint_file_task.rb
#
require File.expand_path("../helper", __FILE__)
require "fileutils"
require "pathname"

class TestRakeFingerprintFileTask < Rake::TestCase
  include Rake

  def setup
    super
    Task.clear
    @runs = Array.new
  end

  def test_fingerprint_file_needed_when_output_missing
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    assert ftask.needed?, "fingerprint file should be needed when output is missing"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_not_needed_after_successful_run
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    assert_equal ["output"], @runs
    refute ftask.needed?, "fingerprint file should not be needed after a successful run"
    assert File.exist?(ftask.fingerprint_record_path), "fingerprint record should exist"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_reruns_when_input_content_changes_but_mtime_restored
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    original_mtime = File.mtime("input")
    File.write("input", "changed content")
    File.utime(original_mtime, original_mtime, "input")
    assert ftask.needed?, "fingerprint file should rerun when input content changes even if mtime is restored"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_skips_when_only_mtime_changes
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    future = Time.now + 3600
    File.utime(future, future, "input")
    refute ftask.needed?, "fingerprint file should skip when only mtime changes and content is unchanged"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_failure_does_not_update_record
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "partial")
      raise "boom"
    end
    ftask = Task["output"]
    assert_raises(RuntimeError) { ftask.invoke }
    refute File.exist?(ftask.fingerprint_record_path), "fingerprint record should not be written on failure"
    assert ftask.needed?, "fingerprint file should still be needed after a failed run"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_input_change_inside_action_invalidates_record
    create_file "input", nil, "original"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("input", "changed inside action")
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute File.exist?(ftask.fingerprint_record_path), "fingerprint record should not be recorded when input changes during the action"
    assert ftask.needed?, "fingerprint file must rerun because input changed during the action"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_reruns_when_output_lost
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    delete_file "output"
    assert ftask.needed?, "fingerprint file should rerun when the output is lost"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_reruns_when_version_changes
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    ftask.version = 2
    assert ftask.needed?, "fingerprint file should rerun when the task version changes"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_non_file_prerequisite_forces_rerun
    task :phony
    create_file "input"
    fingerprint_file "output" => ["input", "phony"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    assert ftask.needed?, "fingerprint file depending on a non-file task must always rerun"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_corrupt_record_triggers_rerun_and_recovers
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    File.write(ftask.fingerprint_record_path, "{corrupt json")
    assert ftask.needed?, "fingerprint file should rerun when the record is corrupt"
    ftask.reenable
    ftask.invoke
    refute ftask.needed?, "fingerprint file should recover after a successful rerun"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_missing_record_triggers_rerun_and_recovers
    create_file "input"
    fingerprint_file "output" => ["input"], :version => 1 do |t|
      @runs << t.name
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    delete_file ftask.fingerprint_record_path
    assert ftask.needed?, "fingerprint file should rerun when the record is missing"
    ftask.reenable
    ftask.invoke
    refute ftask.needed?, "fingerprint file should recover after a successful rerun"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_three_file_demonstration
    create_file "a.in", nil, "alpha"
    create_file "b.in", nil, "beta"
    fingerprint_file "output" => ["a.in", "b.in"], :version => 1 do |t|
      @runs << t.name
      File.write("output", File.read("a.in") + File.read("b.in"))
    end
    ftask = Task["output"]
    ftask.invoke
    assert_equal ["output"], @runs
    refute ftask.needed?
    File.write("a.in", "ALPHA")
    assert ftask.needed?, "should rerun after changing a.in"
    ftask.reenable
    ftask.invoke
    assert_equal ["output", "output"], @runs
    refute ftask.needed?
    File.write("b.in", "BETA")
    assert ftask.needed?, "should rerun after changing b.in"
    ftask.reenable
    ftask.invoke
    assert_equal ["output", "output", "output"], @runs
    refute ftask.needed?
    future = Time.now + 3600
    File.utime(future, future, "a.in")
    File.utime(future, future, "b.in")
    refute ftask.needed?, "should skip when only mtime changes"
  ensure
    delete_file "a.in"
    delete_file "b.in"
    delete_file "output"
  end

  def test_fingerprint_file_record_contains_version_inputs_and_output
    create_file "input", nil, "hello"
    fingerprint_file "output" => ["input"], :version => 7 do |t|
      File.write("output", "HELLO")
    end
    ftask = Task["output"]
    ftask.invoke
    record = JSON.parse(File.read(ftask.fingerprint_record_path))
    assert_equal "7", record["version"]
    assert_equal ["input"], record["inputs"].keys
    assert_equal Digest::SHA256.hexdigest("hello"), record["inputs"]["input"]
    assert_equal Digest::SHA256.hexdigest("HELLO"), record["output"]
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_version_defaults_to_nil
    create_file "input"
    fingerprint_file "output" => ["input"] do |t|
      File.write("output", "result")
    end
    ftask = Task["output"]
    assert_nil ftask.version
    ftask.invoke
    refute ftask.needed?
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_symbol_version_is_recorded_consistently
    create_file "input"
    fingerprint_file "output" => ["input"], :version => :v1 do |t|
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    record = JSON.parse(File.read(ftask.fingerprint_record_path))
    assert_equal "v1", record["version"]
    # Bumping to a string with the same value should not trigger a rerun.
    ftask.version = "v1"
    refute ftask.needed?, "symbol and string versions with the same value should match"
    # Bumping to a different symbol should trigger a rerun.
    ftask.version = :v2
    assert ftask.needed?, "different symbol version should trigger a rerun"
  ensure
    delete_file "input"
    delete_file "output"
  end

  def test_fingerprint_file_without_version_still_detects_change
    create_file "input", nil, "hello"
    fingerprint_file "output" => ["input"] do |t|
      File.write("output", "result")
    end
    ftask = Task["output"]
    ftask.invoke
    refute ftask.needed?
    File.write("input", "changed")
    assert ftask.needed?, "should rerun when input changes even without a version"
  ensure
    delete_file "input"
    delete_file "output"
  end

  private

  def create_file(name, file_time = nil, content = nil)
    FileUtils.mkdir_p(File.dirname(name))
    File.write(name, content || "")
    File.utime(file_time, file_time, name) unless file_time.nil?
    File.stat(name).mtime
  end
end
