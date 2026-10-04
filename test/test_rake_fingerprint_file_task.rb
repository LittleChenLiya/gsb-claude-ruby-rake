# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)
require "rake/fingerprint_file_task"
require "json"

class TestRakeFingerprintFileTask < Rake::TestCase # :nodoc:
  include Rake

  INPUT  = "input.txt"
  OUTPUT = "output.txt"

  def setup
    super
    Task.clear
    @runs = []
  end

  def teardown
    FileUtils.rm_f INPUT
    FileUtils.rm_f OUTPUT
    FileUtils.rm_rf Rake::FingerprintFileTask::DEFAULT_FINGERPRINT_DIR
    super
  end

  def write_input(content, mtime=nil)
    File.write(INPUT, content)
    File.utime(mtime, mtime, INPUT) if mtime
  end

  def build_action
    proc { |t| @runs << t.name; File.write(OUTPUT, "built:" + File.read(INPUT)) }
  end

  def define_task(version: 1, &block)
    block ||= build_action
    fingerprint_file({ OUTPUT => [INPUT] }, version: version, &block)
  end

  def invoke_again(task)
    task.reenable
    task.invoke
  end

  def test_builds_and_records_on_first_run
    write_input "one"
    task = define_task

    task.invoke

    assert_equal [OUTPUT], @runs
    assert File.file?(task.record_path), "record should be written"

    record = JSON.parse(File.read(task.record_path))
    assert_equal 1, record["format"]
    assert_equal "1", record["version"]
    assert_equal [INPUT], record["inputs"].keys
    assert_equal [OUTPUT], record["outputs"].keys
  end

  def test_skips_when_only_mtime_changes
    write_input "one"
    task = define_task
    task.invoke
    assert_equal 1, @runs.size

    future = Time.now + 120
    File.utime(future, future, INPUT) # touch: new mtime, same content

    invoke_again(task)
    assert_equal 1, @runs.size, "mtime-only change must not rebuild"
  end

  def test_reruns_when_content_changes_with_restored_mtime
    stamp = Time.now - 3600
    write_input "one", stamp
    task = define_task
    task.invoke
    assert_equal 1, @runs.size

    write_input "two", stamp # content changed, mtime restored
    assert_equal stamp, File.mtime(INPUT)

    invoke_again(task)
    assert_equal 2, @runs.size, "content change must rebuild despite equal mtime"
    assert_equal "built:two", File.read(OUTPUT)
  end

  def test_failed_action_does_not_update_record
    write_input "one"
    task = fingerprint_file({ OUTPUT => [INPUT] }, version: 1) { |t|
      @runs << t.name
      raise "boom"
    }

    assert_raises(RuntimeError) { task.invoke }
    refute File.exist?(task.record_path), "failed action must not record"

    task.clear_actions
    task.enhance(&build_action)
    invoke_again(task)

    assert_equal [OUTPUT, OUTPUT], @runs
    assert File.file?(task.record_path), "successful rerun records"
  end

  def test_input_changed_during_action_is_not_recorded
    write_input "one"
    mutate = true
    task = fingerprint_file({ OUTPUT => [INPUT] }, version: 1) { |t|
      @runs << t.name
      File.write(OUTPUT, "out")
      if mutate
        mutate = false
        write_input "mutated-during-action" # fixture: input changes mid-action
      end
    }

    task.invoke
    assert File.exist?(OUTPUT)
    refute File.exist?(task.record_path),
      "no completion may be recorded when inputs changed during the action"

    invoke_again(task)
    assert_equal 2, @runs.size, "task must rerun on next invocation"
    assert File.exist?(task.record_path),
      "stable second run records the fingerprint"

    invoke_again(task)
    assert_equal 2, @runs.size, "recorded run is skipped afterwards"
  end

  def test_missing_output_triggers_rerun
    write_input "one"
    task = define_task
    task.invoke
    assert_equal 1, @runs.size

    File.delete OUTPUT

    invoke_again(task)
    assert_equal 2, @runs.size, "missing output must rebuild"
  end

  def test_modified_output_triggers_rerun
    write_input "one"
    task = define_task
    task.invoke

    File.write(OUTPUT, "tampered")

    invoke_again(task)
    assert_equal 2, @runs.size, "output digest mismatch must rebuild"
  end

  def test_version_change_triggers_rerun
    write_input "one"
    task = define_task(version: 1)
    task.invoke
    assert_equal 1, @runs.size

    task.task_version = 2

    invoke_again(task)
    assert_equal 2, @runs.size, "version change must rebuild"

    invoke_again(task)
    assert_equal 2, @runs.size, "new version is recorded"
  end

  def test_missing_record_triggers_rerun
    write_input "one"
    task = define_task
    task.invoke

    File.delete task.record_path

    invoke_again(task)
    assert_equal 2, @runs.size, "missing record must rebuild"
    assert File.file?(task.record_path), "record is rewritten after rebuild"
  end

  def test_corrupt_record_triggers_rerun_and_is_repaired
    write_input "one"
    task = define_task
    task.invoke

    File.write(task.record_path, "{ not json !!!")

    invoke_again(task)
    assert_equal 2, @runs.size, "corrupt record must rebuild"

    record = JSON.parse(File.read(task.record_path))
    assert_equal "1", record["version"], "corrupt record is rewritten"
  end

  def test_stale_tmp_record_is_ignored
    write_input "one"
    task = define_task
    task.invoke

    File.write("#{task.record_path}.tmp-99999", "{ garbage")

    invoke_again(task)
    assert_equal 1, @runs.size, "leftover tmp files never count as completion"
  ensure
    FileUtils.rm_f "#{task.record_path}.tmp-99999"
  end

  def test_non_file_prerequisite_forces_rerun
    write_input "one"
    task :prepare
    t = fingerprint_file({ OUTPUT => [:prepare] }, version: 1, &build_action)

    t.invoke
    invoke_again(t)

    assert_equal 2, @runs.size,
      "documented policy: non-file prerequisites always force a rebuild"
  end

  def test_plain_file_task_keeps_timestamp_semantics
    stamp = Time.now - 3600
    write_input "one", stamp
    file({ OUTPUT => [INPUT] }, &build_action)
    task = Task[OUTPUT]

    task.invoke
    assert_equal 1, @runs.size

    File.utime(Time.now + 120, Time.now + 120, INPUT) # touch only

    task.reenable
    task.invoke
    assert_equal 2, @runs.size, "plain FileTask still rebuilds on newer mtime"
    refute File.exist?(
      File.join(Rake::FingerprintFileTask::DEFAULT_FINGERPRINT_DIR,
                Rake::FingerprintFileTask.record_file_name(OUTPUT))),
      "plain FileTask writes no fingerprint record"
  end
end
