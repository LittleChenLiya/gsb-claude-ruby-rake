# frozen_string_literal: true

# Targeted acceptance tests for Rake::MultiTask explicit cancellation,
# written with Minitest. This file is intentionally NOT named
# test_*.rb, so it is not picked up by the repository's test-unit
# TestTask suite; run it directly:
#
#   ruby -Ilib -Itest test/minitest/multitask_cancel_test.rb
#
# Or with a single test name:
#
#   ruby -Ilib -Itest test/minitest/multitask_cancel_test.rb \
#     -n test_cancel_with_one_worker_skips_queued_dependency_and_parent
require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rake"
require "rake/dsl_definition"

class TestMultiTaskCancel < Minitest::Test
  include Rake::DSL

  def setup
    Rake.application = Rake::Application.new
    # Rake's single-worker mode ("rake -j 1"): no pool worker threads
    # of its own, futures run on the invoking thread in reverse order.
    Rake.application.options.thread_pool_size = 0
  end

  def teardown
    Rake.application.thread_pool.join
  end

  # Acceptance: with one worker, the first (reverse-order) prerequisite
  # blocks while the second is still queued. After cancel the second
  # prerequisite runs 0 times; once the first is released the parent
  # still runs 0 times; the reused worker behaves normally on the next
  # invocation.
  def test_cancel_with_one_worker_skips_queued_dependency_and_parent
    runs = Hash.new(0)
    started = Queue.new
    release = Queue.new

    multitask parent: [:queued, :slow]
    task(:queued) { runs[:queued] += 1 }
    task :slow do
      started << :go
      release.pop
      runs[:slow] += 1
    end
    Rake::Task[:parent].enhance { runs[:parent] += 1 }

    parent = Rake::Task[:parent]
    invoker = Thread.new { parent.invoke }
    started.pop # first dependency is blocked in flight

    # cancel returns only after the in-flight dependency actually ends.
    canceller = Thread.new { parent.cancel }
    Thread.pass until canceller.status == "sleep"
    release << :done
    assert canceller.join

    invoker.join

    # The queued second dependency: 0 runs.
    assert_equal 0, runs[:queued]
    # The started first dependency was allowed to finish: 1 run.
    assert_equal 1, runs[:slow]
    # The parent action never starts: 0 runs.
    assert_equal 0, runs[:parent]
    assert parent.canceled?

    # Pool reuse carries no cancellation state: a fresh, unrelated
    # invocation on the same single worker runs normally.
    Rake.application = Rake::Application.new
    Rake.application.options.thread_pool_size = 0
    multitask next_run: [:ok]
    task(:ok) { runs[:ok] += 1 }
    Rake::Task[:next_run].invoke

    assert_equal 1, runs[:ok]
    refute Rake::Task[:next_run].canceled?
  ensure
    Rake.application.thread_pool.join
  end

  def test_cancel_is_a_noop_without_an_active_invocation
    multitask idle: []
    assert_equal false, Rake::Task[:idle].cancel
    refute Rake::Task[:idle].canceled?
  end

  def test_started_dependency_may_wind_down_cooperatively
    log = []
    started = Queue.new
    release = Queue.new

    multitask coop: [:work] do
      log << :parent
    end
    task :work do
      started << :go
      release.pop
      log << :winding_down if Rake::Task[:coop].canceled?
      log << :done
    end

    coop = Rake::Task[:coop]
    invoker = Thread.new { coop.invoke }
    started.pop
    canceller = Thread.new { coop.cancel }
    Thread.pass until canceller.status == "sleep"
    release << :done
    canceller.join
    invoker.join

    assert_equal [:winding_down, :done], log
    refute_includes log, :parent
  end

  # Ordinary (non-canceled) invocation is completely unaffected: both
  # dependencies and the parent run, and cancellation state never leaks
  # via the worker scope.
  def test_plain_invoke_is_unaffected
    runs = []
    multitask normal: [:a, :b]
    task(:a) { runs << :a }
    task(:b) { runs << :b }
    Rake::Task[:normal].enhance { runs << :parent }

    Rake::Task[:normal].invoke

    assert_includes runs, :a
    assert_includes runs, :b
    assert_includes runs, :parent
    refute Rake::Task[:normal].canceled?
  end

  # Successful tasks keep their normal cache after a canceled
  # invocation; later behavior follows the existing reenable protocol.
  def test_successful_cache_unchanged_and_reenable_protocol_holds
    counts = Hash.new(0)
    started = Queue.new
    release = Queue.new

    multitask parent: [:never_started, :slow]
    task(:never_started) { counts[:never_started] += 1 }
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

    assert_equal 0, counts[:never_started]
    assert_equal 1, counts[:slow]

    # Plain re-invocation runs nothing (normal caching intact).
    parent.invoke
    assert_equal 1, counts[:slow]

    # Reenabling just the parent: the never-started task runs now, the
    # successfully cached one still does not.
    parent.reenable
    parent.invoke
    assert_equal 1, counts[:never_started]
    assert_equal 1, counts[:slow]

    # Reenabling the successful task is what lets it run again.
    Rake::Task[:slow].reenable
    parent.reenable
    parent.invoke
    assert_equal 2, counts[:slow]
  end
end
