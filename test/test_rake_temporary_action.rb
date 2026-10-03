# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeTemporaryAction < Rake::TestCase # :nodoc:
  include Rake

  def setup
    super
    Task.clear
  end

  def test_original_then_temporary_then_original_order
    run = []
    t = task(:work) { run << :original }
    temp = ->(*_) { run << :temporary }

    t.invoke                       # original action before the scope
    t.reenable
    Rake.application.with_temporary_action("work", temp) do
      Rake::Task["work"].invoke    # temporary action inside the scope
    end
    Rake::Task["work"].invoke      # original action after the scope
                                 # (invoke state was restored, no reenable needed)

    assert_equal [:original, :temporary, :original], run
  end

  def test_task_level_entry_point
    run = []
    t = task(:work) { run << :original }

    t.with_temporary_action(->(*_) { run << :temporary }) do
      t.invoke
    end
    t.invoke

    assert_equal [:temporary, :original], run
  end

  def test_invoke_inside_scope_does_not_mark_task_invoked
    run = []
    t = task(:work) { run << :original }

    Rake.application.with_temporary_action("work", ->(*_) { run << :temporary }) do
      t.invoke
    end

    refute t.already_invoked
    t.invoke
    assert_equal [:temporary, :original], run
  end

  def test_previously_invoked_state_is_restored
    run = []
    t = task(:work) { run << :original }
    t.invoke

    Rake.application.with_temporary_action("work", ->(*_) { run << :temporary }) do
      t.reenable
      t.invoke
    end

    assert t.already_invoked
    t.invoke # must not run again: the pre-scope invoked state was restored
    assert_equal [:original, :temporary], run
  end

  def test_prerequisites_are_kept_and_still_invoked_in_scope
    run = []
    task(:dep) { run << :dep }
    t = task(work: [:dep]) { run << :original }

    Rake.application.with_temporary_action("work", ->(*_) { run << :temporary }) do
      t.invoke
    end

    assert_equal [:dep, :temporary], run
    assert_equal ["dep"], t.prerequisites
  end

  def test_nested_overrides_restore_lifo_and_outer_survives_inner_exception
    run = []
    t = task(:work) { run << :original }
    app = Rake.application

    app.with_temporary_action("work", ->(*_) { run << :outer }) do
      t.invoke
      assert_raises(RuntimeError) do
        app.with_temporary_action("work", ->(*_) { run << :inner }) do
          t.reenable
          t.invoke
          raise "boom"
        end
      end
      # inner scope raised, but the outer temporary action is still active
      t.reenable
      t.invoke
    end

    t.invoke
    assert_equal [:outer, :inner, :outer, :original], run
    assert_equal 1, t.actions.size
  end

  def test_exception_restores_original_action_and_state
    run = []
    t = task(:work) { run << :original }

    assert_raises(RuntimeError) do
      Rake.application.with_temporary_action("work", ->(*_) { run << :temporary }) do
        raise "boom"
      end
    end

    t.invoke
    assert_equal [:original], run
    assert_equal 1, t.actions.size
  end

  def test_applications_are_isolated
    app_one = Rake::Application.new
    app_two = Rake::Application.new
    run = []

    Rake.application = app_one
    task(:work) { run << :one }
    Rake.application = app_two
    task(:work) { run << :two }

    app_one.with_temporary_action("work", ->(*_) { run << :temp_one }) do
      app_one["work"].invoke
      app_two["work"].invoke
    end

    assert_equal [:temp_one, :two], run
    assert_equal 1, app_one["work"].actions.size
    assert_equal 1, app_two["work"].actions.size

    app_one["work"].invoke
    app_two["work"].reenable
    app_two["work"].invoke
    assert_equal [:temp_one, :two, :one, :two], run
  end

  def test_full_explicit_task_name_is_required
    run = []
    namespace :ns do
      task(:work) { run << :original }

      # "work" would resolve to "ns:work" through the current scope,
      # but only explicit full names are accepted here.
      ex = assert_raises(RuntimeError) do
        Rake.application.with_temporary_action("work", ->(*_) {}) {}
      end
      assert_match(/work/, ex.message)
    end

    Rake.application.with_temporary_action("ns:work", ->(*_) { run << :temporary }) do
      Rake::Task["ns:work"].invoke
    end
    assert_equal [:temporary], run
  end

  def test_undefined_task_raises
    ex = assert_raises(RuntimeError) do
      Rake.application.with_temporary_action("no:such:task", ->(*_) {}) {}
    end
    assert_match(/no:such:task/, ex.message)
  end

  def test_block_and_action_are_required
    task(:work) {}
    assert_raises(ArgumentError) do
      Rake.application.with_temporary_action("work", ->(*_) {})
    end
    assert_raises(ArgumentError) do
      Rake::Task["work"].with_temporary_action(nil) {}
    end
    assert_raises(ArgumentError) do
      Rake::Task["work"].with_temporary_action(->(*_) {})
    end
  end

  def test_clear_and_reenable_behavior_is_unchanged
    run = []
    t = task(:work) { run << :original }

    t.clear_actions
    assert_empty t.actions
    t.invoke
    assert_equal [], run

    t.reenable
    t.enhance { run << :again }
    t.invoke
    assert_equal [:again], run

    t.clear
    assert_empty t.prerequisites
    assert_empty t.actions
  end

  def test_clear_actions_inside_scope_does_not_touch_original_actions
    t = task(:work) {}
    original = t.actions.dup

    Rake.application.with_temporary_action("work", ->(*_) {}) do
      t.clear_actions
      assert_empty t.actions
    end

    assert_equal original, t.actions
  end
end
