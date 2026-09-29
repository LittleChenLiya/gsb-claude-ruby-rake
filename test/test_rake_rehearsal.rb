# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)
require "pathname"

class TestRakeRehearsal < Rake::TestCase # :nodoc:
  include Rake

  # Injectable file state backed by a fixed hash of path => mtime.
  # Paths absent from the hash are treated as missing files.
  class FakeFileState
    def initialize(times={})
      @times = times
    end

    def exist?(path)
      @times.key?(path)
    end

    def mtime(path)
      stamp = @times[path]
      raise Errno::ENOENT, path if stamp.nil?
      stamp
    end
  end

  # File state whose mtimes drift newer on every call.  A rehearsal must
  # freeze the state it sees, so each path is consulted at most once.
  class VolatileFileState
    attr_reader :mtime_calls

    def initialize(times)
      @times = times
      @mtime_calls = Hash.new(0)
    end

    def exist?(path)
      @times.key?(path)
    end

    def mtime(path)
      @mtime_calls[path] += 1
      raise Errno::ENOENT, path unless @times.key?(path)
      @times[path] + (@mtime_calls[path] - 1) * 10_000
    end
  end

  def setup
    super
    Task.clear
    @t_old = Time.at(1_000)
    @t_mid = Time.at(2_000)
    @t_new = Time.at(3_000)
  end

  def rehearsal(state)
    Rake::Rehearsal.new(Rake.application, file_state: state)
  end

  def test_three_layer_chain_carries_source_change_through
    file "final.out" => ["mid.out"]
    file "mid.out" => ["src.txt"]
    file "src.txt"

    state = FakeFileState.new(
      "src.txt" => @t_new,
      "mid.out" => @t_old,
      "final.out" => @t_old
    )

    report = rehearsal(state).plan("final.out")

    assert_equal ["mid.out", "final.out"], report.task_names
    mid, final = report.entries
    assert_equal ["src.txt"], mid.causes.map(&:name)
    assert_equal ["src.txt"], final.causes.map(&:name)
    assert_match(/final\.out \(out of date: src\.txt\)/, report.to_s)
  end

  def test_equal_timestamps_are_not_out_of_date
    file "out.txt" => ["src.txt"]
    file "src.txt"

    state = FakeFileState.new("src.txt" => @t_mid, "out.txt" => @t_mid)

    report = rehearsal(state).plan("out.txt")

    assert report.empty?
    assert_equal [], report.task_names
  end

  def test_missing_target_is_needed
    file "out.txt" => ["src.txt"]
    file "src.txt"

    state = FakeFileState.new("src.txt" => @t_old)

    report = rehearsal(state).plan("out.txt")

    assert_equal ["out.txt"], report.task_names
    entry = report.entries.first
    assert entry.missing?
    assert_equal [], entry.causes
    assert_match(/out\.txt \(missing\)/, report.to_s)
  end

  def test_plain_tasks_are_always_listed
    task "prep"
    file "out.txt" => ["prep"]

    state = FakeFileState.new("out.txt" => @t_old)

    report = rehearsal(state).plan("out.txt")

    assert_equal ["prep", "out.txt"], report.task_names
    assert_equal ["prep"], report.entries.last.causes.map(&:name)

    solo = rehearsal(state).plan("prep")
    assert_equal ["prep"], solo.task_names
  end

  def test_dynamic_dependencies_from_rule
    file "app.in"
    rule ".out" => [lambda { "app.in" }] do |t|
      raise "rule actions must not run during a rehearsal"
    end

    state = FakeFileState.new("app.in" => @t_new, "app.out" => @t_old)

    report = rehearsal(state).plan("app.out")

    assert_equal ["app.out"], report.task_names
    assert_equal ["app.in"], report.entries.first.causes.map(&:name)
  end

  def test_circular_dependency_is_detected
    task "a" => ["b"]
    task "b" => ["a"]

    ex = assert_raises(RuntimeError) { rehearsal(FakeFileState.new).plan("a") }
    assert_match(/Circular dependency detected/, ex.message)
  end

  def test_file_state_is_fixed_within_one_plan
    file "a.out" => ["b.out"]
    file "b.out"

    state = VolatileFileState.new("a.out" => @t_mid, "b.out" => @t_mid)

    report = rehearsal(state).plan("a.out")

    assert_equal [], report.task_names
    assert_equal 1, state.mtime_calls["a.out"]
    assert_equal 1, state.mtime_calls["b.out"]
  end

  def test_report_order_is_stable
    file "top" => ["m1", "m2"]
    file "m1" => ["src"]
    file "m2" => ["src"]
    file "src"

    state = FakeFileState.new(
      "src" => @t_new,
      "m1" => @t_old,
      "m2" => @t_old,
      "top" => @t_old
    )

    first = rehearsal(state).plan("top")
    second = rehearsal(state).plan("top")

    assert_equal ["m1", "m2", "top"], first.task_names
    assert_equal first.task_names, second.task_names
  end

  def test_actions_are_not_executed_and_no_files_are_written
    ran = []
    file "out.txt" => ["src.txt"] do |t|
      ran << t.name
      File.write(t.name, "x")
    end
    file "src.txt"

    state = FakeFileState.new("src.txt" => @t_new, "out.txt" => @t_old)

    report = rehearsal(state).plan("out.txt")

    assert_equal ["out.txt"], report.task_names
    assert_equal [], ran
    assert !File.exist?("out.txt")
  end

  def test_user_defined_needed_and_timestamp_are_never_called
    klass = Class.new(Rake::FileTask) do
      def needed?
        raise "user defined needed? must not be called by a rehearsal"
      end

      def timestamp
        raise "user defined timestamp must not be called by a rehearsal"
      end
    end
    Rake.application.intern(klass, "custom.out").enhance(["src.txt"])
    file "src.txt"

    state = FakeFileState.new("src.txt" => @t_new, "custom.out" => @t_old)

    report = rehearsal(state).plan("custom.out")

    assert_equal ["custom.out"], report.task_names
    assert_equal ["src.txt"], report.entries.first.causes.map(&:name)
  end

  def test_file_creation_task_is_needed_only_when_missing
    directory "build"

    report = rehearsal(FakeFileState.new).plan("build")
    assert_equal ["build"], report.task_names

    report = rehearsal(FakeFileState.new("build" => @t_old)).plan("build")
    assert_equal [], report.task_names
  end

  def test_default_provider_uses_the_real_file_system
    create_timed_files(OLDFILE, NEWFILE)
    file OLDFILE => [NEWFILE]

    report = Rake::Rehearsal.new(Rake.application).plan(OLDFILE)

    assert_equal [OLDFILE], report.task_names
    assert_equal [NEWFILE], report.entries.first.causes.map(&:name)
  end
end
