# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)
require "thread"

class TestRakeMultiTask < Rake::TestCase # :nodoc:
  include Rake

  def setup
    super

    Task.clear
    @runs = Array.new
    @mutex = Mutex.new
  end

  def teardown
    Rake.application.thread_pool.join

    super
  end

  def add_run(obj)
    @mutex.synchronize do
      @runs << obj
    end
  end

  def test_running_multitasks
    task :a do 3.times do |i| add_run("A#{i}"); sleep 0.01; end end
    task :b do 3.times do |i| add_run("B#{i}"); sleep 0.01;  end end
    multitask both: [:a, :b]
    Task[:both].invoke
    assert_equal 6, @runs.size
    assert @runs.index("A0") < @runs.index("A1")
    assert @runs.index("A1") < @runs.index("A2")
    assert @runs.index("B0") < @runs.index("B1")
    assert @runs.index("B1") < @runs.index("B2")
  end

  def test_all_multitasks_wait_on_slow_prerequisites
    task :slow do 3.times do |i| add_run("S#{i}"); sleep 0.05 end end
    task a: [:slow] do 3.times do |i| add_run("A#{i}"); sleep 0.01 end end
    task b: [:slow] do 3.times do |i| add_run("B#{i}"); sleep 0.01 end end
    multitask both: [:a, :b]
    Task[:both].invoke
    assert_equal 9, @runs.size
    assert @runs.index("S0") < @runs.index("S1")
    assert @runs.index("S1") < @runs.index("S2")
    assert @runs.index("S2") < @runs.index("A0")
    assert @runs.index("S2") < @runs.index("B0")
    assert @runs.index("A0") < @runs.index("A1")
    assert @runs.index("A1") < @runs.index("A2")
    assert @runs.index("B0") < @runs.index("B1")
    assert @runs.index("B1") < @runs.index("B2")
  end

  def test_multitasks_with_parameters
    task :a, [:arg] do |t, args| add_run(args[:arg]) end
    multitask :b, [:arg] => [:a] do |t, args| add_run(args[:arg] + "mt") end
    Task[:b].invoke "b"
    assert @runs[0] == "b"
    assert @runs[1] == "bmt"
  end

  def test_cross_thread_prerequisite_failures
    failed = false

    multitask :fail_once do
      fail_now = !failed
      failed = true
      raise "failing once" if fail_now
    end

    task a: :fail_once
    task b: :fail_once

    assert_raises RuntimeError do
      Rake::Task[:a].invoke
    end

    assert_raises RuntimeError do
      Rake::Task[:b].invoke
    end
  end

  def test_task_not_executed_if_dependant_task_failed_concurrently
    multitask default: [:one, :two]

    task :one do
      raise
    end

    task_two_was_executed = false
    task two: :one do
      task_two_was_executed = true
    end

    begin
      Rake::Task[:default].invoke
    rescue RuntimeError
    ensure
      sleep 0.5
      refute task_two_was_executed
    end
  end

  def test_cancel_skips_queued_prerequisites
    Rake.application.options.thread_pool_size = 1

    release = Queue.new
    started = Queue.new

    task :first do
      add_run("first-start")
      started << :go
      release.pop
      add_run("first-end")
    end

    task :second do
      add_run("second")
    end

    multitask build: [:first, :second] do
      add_run("parent")
    end

    invoke_thread = Thread.new { Rake::Task[:build].invoke }
    started.pop # wait until :first is running (and blocked)

    cancel_thread = Thread.new { Rake::Task[:build].cancel }
    sleep 0.1

    # :second is queued behind :first; it must not have run.
    refute_includes @runs, "second"
    refute_includes @runs, "parent"

    # cancel blocks until in-flight work finishes, so it must still be
    # running while :first is blocked.
    assert cancel_thread.alive?

    release << :go
    cancel_thread.join
    invoke_thread.join

    # :first was allowed to finish, but :second and the parent action did
    # not run.
    assert_includes @runs, "first-start"
    assert_includes @runs, "first-end"
    refute_includes @runs, "second"
    refute_includes @runs, "parent"
  ensure
    Rake.application.thread_pool.join
  end

  def test_cancel_does_not_affect_normal_invoke
    Rake.application.options.thread_pool_size = 1

    task :a do
      add_run("a")
    end

    task :b do
      add_run("b")
    end

    multitask both: [:a, :b] do
      add_run("parent")
    end

    Rake::Task[:both].invoke

    assert_equal ["a", "b", "parent"], @runs
  end

  def test_cancel_reenable_protocol
    Rake.application.options.thread_pool_size = 1

    release = Queue.new
    started = Queue.new

    task :first do
      add_run("first-start")
      started << :go
      release.pop
      add_run("first-end")
    end

    task :second do
      add_run("second")
    end

    multitask build: [:first, :second] do
      add_run("parent")
    end

    invoke_thread = Thread.new { Rake::Task[:build].invoke }
    started.pop

    cancel_thread = Thread.new { Rake::Task[:build].cancel }
    sleep 0.1

    release << :go
    cancel_thread.join
    invoke_thread.join

    refute_includes @runs, "second"
    refute_includes @runs, "parent"

    # Reusing a pooled thread for the next call must work normally.
    task :other do
      add_run("other")
    end
    Rake::Task[:other].invoke
    assert_includes @runs, "other"

    # The normal cache of already-run tasks is unchanged; use the existing
    # reenable protocol to run them again.
    release << :go
    Rake::Task[:build].reenable
    Rake::Task[:first].reenable
    Rake::Task[:second].reenable
    Rake::Task[:build].invoke

    assert_includes @runs, "second"
    assert_includes @runs, "parent"
  ensure
    Rake.application.thread_pool.join
  end
end
