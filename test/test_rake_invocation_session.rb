# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)
require "thread"

class TestRakeInvocationSession < Rake::TestCase # :nodoc:
  include Rake

  def setup
    super

    Task.clear
    @runs = []
    @mutex = Mutex.new
  end

  def teardown
    Rake.application.thread_pool.join

    super
  end

  def add_run(obj)
    @mutex.synchronize { @runs << obj }
  end

  def define_diamond(counter)
    task :base do
      @mutex.synchronize { counter[:base] += 1 }
      add_run("base")
    end
    task left: [:base] do add_run("left") end
    task right: [:base] do add_run("right") end
    task top: [:left, :right]
  end

  def test_diamond_dependency_runs_shared_prerequisite_once_per_session
    counter = { base: 0 }
    define_diamond(counter)

    session = Rake::InvocationSession.new
    session.invoke(:top)
    session.invoke(:top)

    assert_equal 1, counter[:base]
    assert_equal %w[base left right], @runs
  end

  def test_second_session_is_independent_and_runs_again
    counter = { base: 0 }
    define_diamond(counter)

    Rake::InvocationSession.new.invoke(:top)
    Rake::InvocationSession.new.invoke(:top)

    assert_equal 2, counter[:base]
  end

  def test_session_invocation_does_not_mutate_task_definition
    counter = { base: 0 }
    define_diamond(counter)

    base = Task[:base]
    actions = base.actions.dup

    Rake::InvocationSession.new.invoke(:top)

    assert_equal false, base.already_invoked
    assert_equal actions, base.actions
  end

  def test_traditional_invoke_keeps_original_behavior
    counter = { base: 0 }
    define_diamond(counter)

    Task[:top].invoke
    Task[:top].invoke

    assert_equal 1, counter[:base]
    assert_equal true, Task[:base].already_invoked

    Task[:top].all_prerequisite_tasks.each(&:reenable)
    Task[:top].reenable
    Task[:top].invoke

    assert_equal 2, counter[:base]
  end

  def test_failure_propagates_within_session_without_rerunning
    counter = { base: 0 }
    task :base do
      @mutex.synchronize { counter[:base] += 1 }
      raise "boom"
    end
    task left: [:base]
    task right: [:base]
    task top: [:left, :right]

    session = Rake::InvocationSession.new

    ex = assert_raises(RuntimeError) { session.invoke(:top) }
    assert_equal "boom", ex.message

    ex = assert_raises(RuntimeError) { session.invoke(:top) }
    assert_equal "boom", ex.message

    assert_equal 1, counter[:base]
    assert_equal "boom", session.invocation_exception(Task[:base]).message
  end

  def test_failure_in_one_session_does_not_pollute_another
    counter = { base: 0 }
    task :base do
      attempt = nil
      @mutex.synchronize { attempt = (counter[:base] += 1) }
      raise "boom" if attempt == 1
      add_run("base")
    end
    task top: [:base]

    failing_session = Rake::InvocationSession.new
    assert_raises(RuntimeError) { failing_session.invoke(:top) }

    fresh_session = Rake::InvocationSession.new
    fresh_session.invoke(:top)

    assert_equal 2, counter[:base]
    assert_equal %w[base], @runs
    assert_nil fresh_session.invocation_exception(Task[:base])
  end

  def test_multitask_branches_wait_for_shared_prerequisite_result
    entered = Queue.new
    release = Queue.new
    counter = { base: 0 }

    task :base do
      @mutex.synchronize { counter[:base] += 1 }
      entered << true
      release.pop
      add_run("base")
    end
    task left: [:base] do add_run("left") end
    task right: [:base] do add_run("right") end
    multitask top: [:left, :right]

    session = Rake::InvocationSession.new
    worker = Thread.new { session.invoke(:top) }

    entered.pop
    sleep 0.1
    # The shared prerequisite is still running: no branch may proceed.
    assert_equal [], @runs

    release << true
    worker.join(5)

    assert_equal 1, counter[:base]
    assert_equal "base", @runs.first
    assert_equal %w[left right], @runs[1..2].sort
  end

  def test_multitask_concurrent_failure_is_shared_by_all_branches
    entered = Queue.new
    release = Queue.new
    counter = { base: 0 }

    task :base do
      @mutex.synchronize { counter[:base] += 1 }
      entered << true
      release.pop
      raise "concurrent boom"
    end
    task left: [:base]
    task right: [:base]
    multitask top: [:left, :right]

    session = Rake::InvocationSession.new
    errors = Queue.new
    worker = Thread.new do
      begin
        session.invoke(:top)
      rescue => ex
        errors << ex
      end
    end

    entered.pop
    sleep 0.1 # give the second branch time to block on the session lock
    release << true
    worker.join(5)

    assert_equal 1, counter[:base]
    assert_equal "concurrent boom", errors.pop.message

    # Both branches see the recorded failure without re-running the task.
    assert_raises(RuntimeError) { session.invoke(:left) }
    assert_raises(RuntimeError) { session.invoke(:right) }
    assert_equal 1, counter[:base]
  end

  def test_recursive_invocation_chain_detects_circular_dependencies
    session = Rake::InvocationSession.new

    task :a do
      session.invoke(:b)
    end
    task :b do
      session.invoke(:a)
    end

    ex = assert_raises(RuntimeError) { session.invoke(:a) }
    assert_match(/Circular dependency detected/, ex.message)
  end

  def test_task_arguments_are_isolated_between_sessions
    received = []
    task :greet, [:name] do |_t, args|
      @mutex.synchronize { received << args[:name] }
    end

    Rake::InvocationSession.new.invoke(:greet, "alice")
    Rake::InvocationSession.new.invoke(:greet, "bob")

    assert_equal %w[alice bob], received
  end

  def test_task_arguments_are_isolated_between_invocations_in_one_session
    received = []
    task :child, [:value] do |_t, args|
      @mutex.synchronize { received << args[:value] }
    end
    task :parent, [:value] => [:child] do |_t, args|
      @mutex.synchronize { received << "parent:" + args[:value] }
    end

    session = Rake::InvocationSession.new
    session.invoke(:parent, "one")

    assert_equal %w[one parent:one], received
  end

  def test_application_invocation_session_factory
    session = Rake.application.invocation_session

    assert_kind_of Rake::InvocationSession, session
    assert_same Rake.application, session.application
  end

  def test_session_lookup_uses_its_application
    task :base

    session = Rake::InvocationSession.new

    assert_same Task[:base], session[:base]
  end
end
