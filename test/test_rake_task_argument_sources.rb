# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeTaskArgumentSources < Rake::TestCase # :nodoc:
  include Rake

  def setup
    super
    Task.clear
  end

  def test_parent_passes_arguments_to_two_dependencies
    child1_trace = nil
    child2_trace = nil

    task :child1, [:a, :c] do |t, args|
      args.with_defaults(c: "default_c")
      child1_trace = args.trace
    end

    task :child2, [:b, :d] do |t, args|
      args.with_defaults(d: "default_d")
      child2_trace = args.trace
    end

    task :parent, [:a, :b] => [:child1, :child2] do |t, args|
      # parent body
    end

    parent = Task[:parent]
    parent.invoke("x", "y")

    assert_equal(
      { a: { kind: :forwarded, scope: "parent" },
        c: { kind: :default, scope: "child1" } },
      child1_trace
    )
    assert_equal(
      { b: { kind: :forwarded, scope: "parent" },
        d: { kind: :default, scope: "child2" } },
      child2_trace
    )
  end

  def test_dependency_defaults_only_apply_when_value_missing
    child_trace = nil

    task :child, [:a, :b] do |t, args|
      args.with_defaults(a: "default_a", b: "default_b")
      child_trace = args.trace
    end

    task :parent, [:a, :b] => [:child]

    parent = Task[:parent]
    parent.invoke("x", nil)

    assert_equal(
      { a: { kind: :forwarded, scope: "parent" },
        b: { kind: :default, scope: "child" } },
      child_trace
    )
  end

  def test_second_invocation_is_recorded_as_skipped
    task :child, [:a] do |t, args|
      args.with_defaults(a: "default_a")
    end

    task :parent, [:a] => [:child]

    parent = Task[:parent]
    parent.invoke("x")

    assert_equal true, parent.last_args.bound
    assert_equal(
      { a: { kind: :actual, scope: "parent" } },
      parent.last_args.trace
    )

    # Second invocation: parent is already invoked, should be skipped
    parent.invoke("x")

    assert_equal false, parent.last_args.bound
    assert_equal(
      { a: { kind: :actual, scope: "parent" } },
      parent.last_args.trace
    )
  end

  def test_scope_recovery_does_not_leak_between_invocations
    task :child, [:a] do |t, args|
      args.with_defaults(a: "default_a")
    end

    task :parent, [:a] => [:child]

    parent = Task[:parent]
    parent.invoke("first")

    assert_equal "parent", parent.last_args.scope
    assert_equal(
      { a: { kind: :actual, scope: "parent" } },
      parent.last_args.trace
    )

    # Re-enable and invoke again with different args
    parent.reenable
    parent.invoke("second")

    assert_equal "parent", parent.last_args.scope
    assert_equal(
      { a: { kind: :actual, scope: "parent" } },
      parent.last_args.trace
    )
    assert_equal "second", parent.last_args[:a]
  end

  def test_same_named_arguments_are_independent_across_tasks
    task :task1, [:a] do |t, args|
      args.with_defaults(a: "default1")
    end

    task :task2, [:a] do |t, args|
      args.with_defaults(a: "default2")
    end

    task1 = Task[:task1]
    task2 = Task[:task2]

    task1.invoke(nil)
    task2.invoke(nil)

    assert_equal(
      { a: { kind: :default, scope: "task1" } },
      task1.last_args.trace
    )
    assert_equal(
      { a: { kind: :default, scope: "task2" } },
      task2.last_args.trace
    )
    assert_equal "default1", task1.last_args[:a]
    assert_equal "default2", task2.last_args[:a]
  end

  def test_trace_contains_no_values
    captured_trace = nil

    task :secret_task, [:secret] do |t, args|
      captured_trace = args.trace
    end

    secret_task = Task[:secret_task]
    secret_task.invoke("s3cr3t_value")

    assert_equal(
      { secret: { kind: :actual, scope: "secret_task" } },
      captured_trace
    )
    refute_includes captured_trace.inspect, "s3cr3t_value"
  end

  def test_application_isolation
    app1 = Rake::Application.new
    app2 = Rake::Application.new

    Rake.application = app1
    task :t, [:a] do |t, args|
      args.with_defaults(a: "default_app1")
    end
    t1 = Task[:t]
    t1.invoke(nil)

    Rake.application = app2
    task :t, [:a] do |t, args|
      args.with_defaults(a: "default_app2")
    end
    t2 = Task[:t]
    t2.invoke(nil)

    assert_equal(
      { a: { kind: :default, scope: "t" } },
      t1.last_args.trace
    )
    assert_equal(
      { a: { kind: :default, scope: "t" } },
      t2.last_args.trace
    )
    assert_equal "default_app1", t1.last_args[:a]
    assert_equal "default_app2", t2.last_args[:a]
  ensure
    Rake.application = Rake::Application.new
  end
end
