# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeTaskActionScope < Rake::TestCase # :nodoc:
  include Rake

  def setup
    super

    Task.clear
    Rake::TaskManager.record_task_metadata = true
  end

  def teardown
    Rake::TaskManager.record_task_metadata = false
    Rake.application.thread_pool.join

    super
  end

  # Run the task and record which action ran, returning the runlist.
  def run_task(name)
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  end

  def test_action_is_replaced_and_restored
    runlist = []
    task(:foo) { runlist << :original }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { runlist << :temporary }
      Rake::Task[:foo].invoke
    end
    run_task(:foo)

    assert_equal [:temporary, :original], runlist
  end

  def test_original_action_is_restored_after_scope
    runlist = []
    task(:foo) { runlist << :original }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { runlist << :temporary }
    end

    assert_equal 1, Rake::Task[:foo].actions.size
    run_task(:foo)
    assert_equal [:original], runlist
  end

  def test_previous_invoke_state_is_restored
    task(:foo) { 1234 }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { 4321 }
      Rake::Task[:foo].invoke
    end

    refute Rake::Task[:foo].already_invoked,
           "temporary execution must not mark the task as completed"
    assert_nil Rake::Task[:foo].invocation_exception
  end

  def test_previously_invoked_state_is_preserved
    task(:foo) { 1234 }
    Rake::Task[:foo].invoke

    Rake::Task.with_action(:foo) do |scope|
      scope.action { 4321 }
      Rake::Task[:foo].invoke
    end

    assert Rake::Task[:foo].already_invoked,
           "previous invoke state must be restored"
  end

  def test_nested_scopes_restore_actions_in_lifo_order
    runlist = []
    task(:foo) { runlist << :original }

    Rake::Task.with_action(:foo) do |outer|
      outer.action { runlist << :outer }
      Rake::Task[:foo].invoke

      Rake::Task.with_action(:foo) do |inner|
        inner.action { runlist << :inner }
        Rake::Task[:foo].invoke
      end

      # inner scope restored to the outer temporary action
      assert_equal 1, Rake::Task[:foo].actions.size
      run_task(:foo)
    end

    # outer scope restored to the original action
    assert_equal 1, Rake::Task[:foo].actions.size
    run_task(:foo)

    assert_equal [:outer, :inner, :outer, :original], runlist
  end

  def test_inner_exception_restores_outer_temporary_action
    runlist = []
    task(:foo) { runlist << :original }

    Rake::Task.with_action(:foo) do |outer|
      outer.action { runlist << :outer }
      begin
        Rake::Task.with_action(:foo) do |inner|
          inner.action { runlist << :inner }
          raise "boom"
        end
      rescue RuntimeError => ex
        assert_equal "boom", ex.message
        # inner scope must restore to the outer temporary action
        assert_equal 1, Rake::Task[:foo].actions.size
        run_task(:foo)
      end
    end

    run_task(:foo)

    assert_equal [:outer, :original], runlist
  end

  def test_exception_in_temporary_action_restores_state
    task(:foo) { 1234 }

    assert_raises(RuntimeError) do
      Rake::Task.with_action(:foo) do |scope|
        scope.action { raise "temporary failure" }
        Rake::Task[:foo].invoke
      end
    end

    assert_equal 1, Rake::Task[:foo].actions.size
    refute Rake::Task[:foo].already_invoked
    assert_nil Rake::Task[:foo].invocation_exception
  end

  def test_dependencies_are_not_deleted
    task(foo: [:bar]) { 1234 }
    task(:bar) { 5678 }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { 4321 }
    end

    assert_equal ["bar"], Rake::Task[:foo].prerequisites
    assert_equal 1, Rake::Task[:bar].actions.size
  end

  def test_dependency_invoke_state_is_restored
    runlist = []
    task(foo: [:bar]) { runlist << :foo }
    task(:bar) { runlist << :bar }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { runlist << :temporary_foo }
      Rake::Task[:foo].invoke
    end

    refute Rake::Task[:bar].already_invoked,
           "temporary execution must not mark dependencies as completed"
    run_task(:foo)

    assert_equal [:bar, :temporary_foo, :bar, :foo], runlist
  end

  def test_only_the_given_task_is_affected
    runlist = []
    task(:foo) { runlist << :foo_original }
    task(:bar) { runlist << :bar_original }

    Rake::Task.with_action(:foo) do |scope|
      scope.action { runlist << :foo_temporary }
      Rake::Task[:foo].invoke
    end

    run_task(:foo)
    run_task(:bar)

    assert_equal [:foo_temporary, :foo_original, :bar_original], runlist
  end

  def test_raises_for_unknown_task
    assert_raises(RuntimeError) do
      Rake::Task.with_action(:unknown_task) { |scope| scope.action { 1 } }
    end
  end

  def test_application_scopes_are_isolated
    runlist = []
    app1 = Rake::Application.new
    app2 = Rake::Application.new

    Rake.with_application(app1) do
      task(:same) { runlist << :app1_original }
    end
    Rake.with_application(app2) do
      task(:same) { runlist << :app2_original }
    end

    Rake.with_application(app1) do
      Rake::Task.with_action(:same) do |scope|
        scope.action { runlist << :app1_temporary }
        run_task(:same)
      end
      run_task(:same)
    end

    # app2 must be completely unaffected by app1's scope
    Rake.with_application(app2) do
      assert_equal 1, Rake::Task[:same].actions.size
      run_task(:same)
    end

    assert_equal [:app1_temporary, :app1_original, :app2_original], runlist
  end

  def test_clear_and_reenable_behavior_is_unchanged
    task(:foo) { 1234 }
    Rake::Task[:foo].invoke
    assert Rake::Task[:foo].already_invoked

    Rake::Task[:foo].reenable
    refute Rake::Task[:foo].already_invoked

    Rake::Task[:foo].clear
    assert_empty Rake::Task[:foo].actions
    assert_empty Rake::Task[:foo].prerequisites
  end

  def test_action_scope_stack_is_per_application
    app1 = Rake::Application.new
    app2 = Rake::Application.new

    Rake.with_application(app1) do
      task(:foo) { 1 }
      Rake::Task.with_action(:foo) do |scope|
        assert_equal 1, Rake.application.action_scope_stack.size
        scope.action { 2 }

        Rake.with_application(app2) do
          task(:foo) { 3 }
          # app2's stack is independent of app1's active scope
          assert_empty Rake.application.action_scope_stack
        end
      end
    end
  end

  def test_instance_with_action_entry_point
    runlist = []
    task(:foo) { runlist << :original }

    Rake::Task[:foo].with_action do |scope|
      scope.action { runlist << :temporary }
      Rake::Task[:foo].invoke
    end
    run_task(:foo)

    assert_equal [:temporary, :original], runlist
  end
end
