# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeTaskPreview < Rake::TestCase # :nodoc:
  include Rake

  # An in memory, injectable source of file system state.  Maps file names
  # to their modification times; missing names raise Errno::ENOENT from
  # #mtime, matching the real FileStatus contract.
  class FakeFileStatus
    attr_reader :exist_queries, :mtime_queries

    def initialize(times = {})
      @times = times
      @exist_queries = []
      @mtime_queries = []
    end

    def exist?(file_name)
      @exist_queries << file_name
      @times.key?(file_name)
    end

    def mtime(file_name)
      @mtime_queries << file_name
      @times.fetch(file_name) { raise Errno::ENOENT, file_name }
    end

    def query_count(file_name)
      @exist_queries.count(file_name) + @mtime_queries.count(file_name)
    end
  end

  def setup
    super
    Task.clear
    @ran = []
    @now = Time.now
  end

  def three_layer_graph
    file "src.c"           do |t| @ran << t.name end
    file "mid.o" => ["src.c"] do |t| @ran << t.name end
    file "app.exe" => ["mid.o"] do |t| @ran << t.name end
  end

  def test_three_layer_chain_reports_both_affected_layers
    three_layer_graph
    status = FakeFileStatus.new(
      "src.c" => @now + 100,
      "mid.o" => @now,
      "app.exe" => @now - 100
    )

    report = Rake::TaskPreview.preview("app.exe", status)

    assert_equal ["mid.o", "app.exe"], report.needed_names
    by_name = entries_by_name(report)
    assert by_name["mid.o"].stale?
    assert_equal ["src.c"], by_name["mid.o"].causes
    assert by_name["app.exe"].stale?
    assert_include by_name["app.exe"].causes, "src.c"
    assert_include by_name["app.exe"].causes, "mid.o"
    refute report.needed_names.include?("src.c")
    assert_empty @ran
  end

  def test_equal_timestamps_are_up_to_date
    three_layer_graph
    status = FakeFileStatus.new(
      "src.c" => @now,
      "mid.o" => @now,
      "app.exe" => @now
    )

    report = Rake::TaskPreview.preview("app.exe", status)

    assert_empty report.needed_names
    assert_equal 3, report.entries.size
  end

  def test_missing_target_is_reported_as_missing
    three_layer_graph
    status = FakeFileStatus.new(
      "src.c" => @now,
      "mid.o" => @now
    )

    report = Rake::TaskPreview.preview("app.exe", status)

    assert_equal ["app.exe"], report.needed_names
    entry = entries_by_name(report)["app.exe"]
    assert entry.missing?
    assert_match(/missing/, entry.to_s)
  end

  def test_plain_task_is_always_needed
    file "src.c" do |t| @ran << t.name end
    task "build" => ["src.c"] do |t| @ran << t.name end
    status = FakeFileStatus.new("src.c" => @now)

    report = Rake::TaskPreview.preview("build", status)

    assert_equal ["build"], report.needed_names
    entry = entries_by_name(report)["build"]
    assert entry.always_needed?
    assert_empty entry.causes
    assert_empty @ran
  end

  def test_dynamic_dependency_is_resolved_through_rule
    rule(".o" => ".c") { |t| @ran << t.name }
    status = FakeFileStatus.new(
      "x.c" => @now + 100,
      "x.o" => @now
    )

    report = Rake::TaskPreview.preview("x.o", status)

    assert_equal ["x.o"], report.needed_names
    entry = entries_by_name(report)["x.o"]
    assert_instance_of FileTask, entry.task
    assert_equal ["x.c"], entry.causes
    assert_empty @ran
  end

  def test_cycle_is_reported
    file "a" => ["b"]
    file "b" => ["a"]
    status = FakeFileStatus.new

    error = assert_raises(RuntimeError) do
      Rake::TaskPreview.preview("a", status)
    end
    assert_match(/Circular dependency detected/, error.message)
    assert_match(/a => b => a/, error.message)
  end

  def test_file_state_is_fixed_for_one_preview
    three_layer_graph

    # Alternates its answer on every query.  Without the per preview
    # snapshot a missing file could appear and disappear mid traversal.
    status = Object.new
    toggled = false
    status.define_singleton_method(:exist?) do |file_name|
      toggled = !toggled
      file_name == "src.c" ? true : false
    end
    status.define_singleton_method(:mtime) do |file_name|
      raise Errno::ENOENT, file_name unless file_name == "src.c"
      @now
    end

    report = Rake::TaskPreview.preview("app.exe", status)

    names = report.entries.map(&:name)
    assert_equal ["src.c", "mid.o", "app.exe"], names
    assert_equal ["mid.o", "app.exe"], report.needed_names
    assert entries_by_name(report)["mid.o"].missing?
    assert entries_by_name(report)["app.exe"].missing?
  end

  def test_each_path_is_queried_at_most_once_per_method
    three_layer_graph
    status = FakeFileStatus.new(
      "src.c" => @now + 100,
      "mid.o" => @now,
      "app.exe" => @now - 100
    )

    Rake::TaskPreview.preview("app.exe", status)

    ["src.c", "mid.o", "app.exe"].each do |name|
      assert_equal 1, status.exist_queries.count(name),
                     "#{name} existence queried repeatedly"
      assert_equal 1, status.mtime_queries.count(name),
                     "#{name} mtime queried repeatedly"
    end
  end

  def test_report_order_is_stable
    file "a.c"
    file "b.c"
    file "out" => ["a.c", "b.c"]
    status = FakeFileStatus.new(
      "a.c" => @now + 100,
      "b.c" => @now + 100,
      "out" => @now
    )

    first = Rake::TaskPreview.preview("out", status).needed_names
    second = Rake::TaskPreview.preview("out", status).needed_names

    assert_equal ["out"], first
    assert_equal first, second

    entries = Rake::TaskPreview.preview("out", status).entries.map(&:name)
    assert_equal ["a.c", "b.c", "out"], entries
  end

  def test_preview_does_not_execute_actions_or_write_files
    ran = false
    file "generated" do
      ran = true
      File.write("generated", "data")
    end
    status = FakeFileStatus.new

    Rake::TaskPreview.preview("generated", status)

    refute ran
    refute File.exist?("generated")
  end

  def test_preview_does_not_call_user_defined_needed
    three_layer_graph
    custom = Class.new(FileTask) do
      define_method(:needed?) do
        raise "user defined needed? must not be called"
      end
    end
    custom_task = Rake.application.intern(custom, "custom.o")
    custom_task.enhance(["src.c"])
    status = FakeFileStatus.new("src.c" => @now + 100)

    report = Rake::TaskPreview.preview(custom_task, status)

    assert_equal ["custom.o"], report.needed_names
    assert entries_by_name(report)["custom.o"].always_needed?
  end

  def test_accepts_task_object_target
    three_layer_graph
    status = FakeFileStatus.new

    report = Rake::TaskPreview.new(Task["app.exe"], status).run

    assert_equal ["src.c", "mid.o", "app.exe"], report.needed_names
  end

  def test_default_file_status_uses_real_file_system
    create_timed_files(OLDFILE, NEWFILE)
    file OLDFILE => [NEWFILE]

    report = Rake::TaskPreview.preview(OLDFILE)

    assert_equal [OLDFILE], report.needed_names
    assert_equal [NEWFILE], entries_by_name(report)[OLDFILE].causes
  ensure
    delete_file(OLDFILE)
    delete_file(NEWFILE)
  end

  def test_report_to_s_is_readable
    three_layer_graph
    status = FakeFileStatus.new(
      "src.c" => @now + 100,
      "mid.o" => @now,
      "app.exe" => @now - 100
    )

    output = Rake::TaskPreview.preview("app.exe", status).to_s

    assert_match(/mid\.o .stale due to src\.c./, output)
    assert_match(/app\.exe .stale due to.*src\.c/, output)
  end

  def test_unknown_task_raises_like_real_invocation
    status = FakeFileStatus.new

    assert_raises(RuntimeError) do
      Rake::TaskPreview.preview("does-not-exist", status)
    end
  end

  def test_file_creation_task_is_needed_only_when_missing
    directory "gen"
    file "gen/out.c"
    file "gen/out.o" => ["gen", "gen/out.c"]

    missing = FakeFileStatus.new("gen/out.c" => @now)
    report = Rake::TaskPreview.preview("gen/out.o", missing)

    assert_equal ["gen", "gen/out.o"], report.needed_names
    assert entries_by_name(report)["gen"].missing?

    present = FakeFileStatus.new(
      "gen" => @now,
      "gen/out.c" => @now + 100,
      "gen/out.o" => @now
    )
    report = Rake::TaskPreview.preview("gen/out.o", present)
    assert_equal ["gen/out.o"], report.needed_names
  end

  def test_status_provider_is_restored_after_preview
    rule(".o" => ".c")
    status = FakeFileStatus.new(
      "y.c" => @now,
      "y.o" => @now
    )

    Rake::TaskPreview.preview("y.o", status)

    assert_instance_of Rake::FileStatus, Rake.application.file_status
  end

  private

  def entries_by_name(report)
    report.entries.each_with_object({}) { |entry, map| map[entry.name] = entry }
  end
end
