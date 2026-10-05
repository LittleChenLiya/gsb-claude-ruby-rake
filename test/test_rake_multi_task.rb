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

  # Rake's single-worker mode ("rake -j 1"): the pool has no worker
  # threads of its own, so prerequisites are performed on the invoking
  # thread in reverse order. The first (reverse-order) prerequisite can
  # block while the others remain merely queued.
  def with_single_worker
    Rake.application.options.thread_pool_size = 0
    yield
  ensure
    Rake.application.thread_pool.join
  end

  def test_explicit_cancel_skips_unstarted_prerequisite_and_parent
    runs = Hash.new(0)
    started = Queue.new
    release = Queue.new

    with_single_worker do
      # Prerequisites are performed in reverse order, so declare the
      # blocking one last: it runs first while +queued+ stays queued.
      multitask parent: [:queued, :slow]
      task :queued do
        runs[:queued] += 1
      end
      task :slow do
        started << :go
        release.pop
        runs[:slow] += 1
      end
      runs[:parent] = 0
      Rake::Task[:parent].enhance do
        runs[:parent] += 1
      end

      parent = Rake::Task[:parent]
      invoker = Thread.new { parent.invoke }

      # Wait until the first prerequisite is genuinely in flight ...
      assert_equal :go, started.pop
      # ... then cancel while the second prerequisite is still queued.
      # #cancel waits for the in-flight prerequisite to actually finish,
      # so release it from a separate thread.
      canceller = Thread.new { parent.cancel }
      Thread.pass until canceller.status == "sleep"
      release << :done
      assert canceller.join

      # The queued prerequisite never started.
      refute Rake::Task[:queued].already_invoked
      assert_equal 0, runs[:queued]

      invoker.join

      assert_equal 1, runs[:slow]
      # The parent's own actions never start after cancellation.
      assert_equal 0, runs[:parent]
      assert parent.canceled?
    end
  end

  def test_cancel_returns_false_without_active_invocation
    multitask standalone: []
    assert_equal false, Rake::Task[:standalone].cancel
  end

  def test_started_prerequisite_is_allowed_to_finish_cooperatively
    log = []
    started = Queue.new
    release = Queue.new

    with_single_worker do
      multitask coop: [:work] do
        log << :parent
      end
      task :work do
        started << :go
        release.pop
        # A running prerequisite may observe cancellation cooperatively.
        log << :winding_down if Rake::Task[:coop].canceled?
        log << :work_done
      end

      coop = Rake::Task[:coop]
      invoker = Thread.new { coop.invoke }
      started.pop
      canceller = Thread.new { coop.cancel }
      Thread.pass until canceller.status == "sleep"
      release << :done
      canceller.join
      invoker.join

      assert_equal [:winding_down, :work_done], log
      refute_includes log, :parent
    end
  end

  def test_cancel_does_not_pollute_the_next_invocation
    runs = []

    with_single_worker do
      # First invocation: cancel while its only prerequisite is blocked.
      started = Queue.new
      release = Queue.new
      multitask first: [:blocked]
      task :blocked do
        started << :go
        release.pop
        runs << :blocked
      end

      first = Rake::Task[:first]
      invoker = Thread.new { first.invoke }
      started.pop
      canceller = Thread.new { first.cancel }
      Thread.pass until canceller.status == "sleep"
      release << :done
      canceller.join
      invoker.join

      # A second, unrelated invocation runs normally: cancellation
      # context is visible only within the first invocation's scope and
      # is not carried over when the worker is reused.
      Task.clear
      Rake.application.options.thread_pool_size = 0
      multitask second: [:ok]
      task :ok do
        runs << :ok
      end
      Rake::Task[:second].invoke

      assert_equal [:blocked, :ok], runs
      refute Rake::Task[:second].canceled?
    end
  end

  def test_successful_prerequisite_cache_is_kept_after_cancel
    counts = Hash.new(0)

    with_single_worker do
      started = Queue.new
      release = Queue.new
      # Reverse order performs :slow first; :done has not started yet
      # when cancellation happens.
      multitask parent: [:done, :slow]
      task :done do
        counts[:done] += 1
      end
      task :slow do
        started << :go
        release.pop if counts[:slow].zero?
        counts[:slow] += 1
      end

      parent = Rake::Task[:parent]
      invoker = Thread.new { parent.invoke }
      started.pop
      canceller = Thread.new { parent.cancel }
      Thread.pass until canceller.status == "sleep"
      release << :done
      canceller.join
      invoker.join

      assert_equal 0, counts[:done]
      assert_equal 1, counts[:slow]

      # Following the existing reenable protocol: a plain re-invocation
      # runs nothing (the cached in-flight result is untouched) ...
      parent.invoke
      assert_equal 1, counts[:slow]

      # ... after reenabling the parent, a prerequisite that never
      # started simply runs as normal (it was never invoked, so there is
      # no cached state to clear), while the prerequisite that had
      # completed successfully stays cached and is not re-run.
      parent.reenable
      parent.invoke
      assert_equal 1, counts[:done]
      assert_equal 1, counts[:slow]

      # The successful task's normal caching is unchanged: it runs again
      # only once it itself is reenabled.
      Rake::Task[:slow].reenable
      parent.reenable
      parent.invoke
      assert_equal 2, counts[:slow]
      assert_equal 1, counts[:done]
    end
  end

  def test_plain_invoke_is_unaffected_without_cancel
    runs = []
    with_single_worker do
      multitask normal: [:a, :b]
      task :a do runs << :a end
      task :b do runs << :b end
      Rake::Task[:normal].enhance { runs << :parent }

      Rake::Task[:normal].invoke

      assert_includes runs, :a
      assert_includes runs, :b
      assert_includes runs, :parent
      refute Rake::Task[:normal].canceled?
    end
  end

  def test_cancel_with_multiple_workers_and_pool_thread_reuse
    # Two real pool workers plus the invoking thread (which performs a
    # queued future itself through Promise#value) can occupy at most
    # three prerequisites; a fourth therefore stays genuinely queued.
    # Cancellation lets the three in-flight prerequisites finish, skips
    # the queued one and the parent, and the reused worker threads serve
    # a later invocation without carrying canceled state.
    Rake.application.options.thread_pool_size = 2
    runs = Hash.new(0)
    started = Queue.new
    releases = {}

    # Futures enter the pool queue in prerequisites order and workers
    # dequeue FIFO (slow, mid), while the invoking thread performs the
    # last-declared future itself (other); +queued+ is the one that
    # stays genuinely unstarted.
    multitask parent: [:slow, :mid, :queued, :other]
    %i[slow mid other].each do |name|
      releases[name] = Queue.new
      q = releases[name]
      task name do
        started << name
        q.pop
        runs[name] += 1
      end
    end
    task :queued do
      runs[:queued] += 1
    end
    Rake::Task[:parent].enhance { runs[:parent] += 1 }

    parent = Rake::Task[:parent]
    invoker = Thread.new { parent.invoke }
    in_flight = 3.times.map { started.pop }.sort
    assert_equal %i[mid other slow], in_flight
    refute Rake::Task[:queued].already_invoked

    canceller = Thread.new { parent.cancel }
    Thread.pass until canceller.status == "sleep"
    # #cancel returns only once all in-flight prerequisites end.
    releases.each_value { |q| q << :done }
    canceller.join
    invoker.join
    Rake.application.thread_pool.join

    assert_equal 0, runs[:queued]
    assert_equal 1, runs[:slow]
    assert_equal 1, runs[:mid]
    assert_equal 1, runs[:other]
    assert_equal 0, runs[:parent]

    # Reuse the same pool workers for an ordinary invocation.
    multitask next_run: [:ok]
    task :ok do
      runs[:ok] += 1
    end
    Rake::Task[:next_run].invoke
    Rake.application.thread_pool.join

    assert_equal 1, runs[:ok]
    refute Rake::Task[:next_run].canceled?
  end
end
