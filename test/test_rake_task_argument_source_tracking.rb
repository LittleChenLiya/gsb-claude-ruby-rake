# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

# Tests for explicit TaskArguments source tracking.
#
# Run with:
#   ruby -Ilib -Itest test/test_rake_task_argument_source_tracking.rb
class TestRakeTaskArgumentSourceTracking < Rake::TestCase # :nodoc:
  def setup
    super
    @app = Rake.application
  end

  # Three-task example: a parent task forwards its +msg+ argument to
  # two prerequisite tasks, each of which may fall back to a default
  # +level+.
  def define_three_task_example
    Rake::Task.define_task("parent", [:msg] => ["left", "right"])
    Rake::Task.define_task("left",  [:msg, :level]) do |_, args|
      args.with_defaults(level: "left-default")
    end
    Rake::Task.define_task("right", [:msg, :level]) do |_, args|
      args.with_defaults(level: "right-default")
    end
  end

  def trace_entries_for(task_name, event=nil)
    @app.argument_source_trace.select { |e|
      e[:task] == task_name && (event.nil? || e[:event] == event)
    }
  end

  def test_explicit_arguments_are_tracked_as_argument_source
    ta = Rake::TaskArguments.new([:a, :b], [1, 2])
    assert_equal :argument, ta.source_of(:a)
    assert_equal :argument, ta.source_of(:b)
    assert_nil ta.source_of(:c)
    assert_equal({ a: :argument, b: :argument }, ta.source_trace)
  end

  def test_forwarded_arguments_record_the_real_scope_chain
    parent = Rake::TaskArguments.new([:msg], ["hello"])
    child = parent.new_scope([:msg, :level])

    assert_equal :forwarded, child.source_of(:msg)
    assert_equal [:forwarded, :argument], child.source_chain(:msg)
    assert_equal({ msg: :forwarded }, child.source_trace)
    # The parent scope is untouched by the child scope.
    assert_equal({ msg: :argument }, parent.source_trace)
  end

  def test_defaults_are_recorded_only_when_value_is_missing
    ta = Rake::TaskArguments.new([:msg, :level], ["hello", nil])
    ta.with_defaults(level: "info", msg: "ignored")

    assert_equal "hello", ta[:msg]
    assert_equal "info", ta[:level]
    assert_equal :argument, ta.source_of(:msg)
    assert_equal :default, ta.source_of(:level)
  end

  def test_defaults_are_not_recorded_more_than_once
    ta = Rake::TaskArguments.new([:level], [nil])
    ta.with_defaults(level: "first")
    ta.with_defaults(level: "second")

    assert_equal "first", ta[:level]
    assert_equal [:default], ta.source_chain(:level)
    assert_equal({ level: :default }, ta.source_trace)
  end

  def test_same_named_arguments_are_independent_per_task
    Rake::Task.define_task("t1", [:v])
    Rake::Task.define_task("t2", [:v])

    Rake::Task["t1"].invoke("one")
    Rake::Task["t2"].invoke("two")

    t1 = trace_entries_for("t1", :bind).last
    t2 = trace_entries_for("t2", :bind).last
    assert_equal({ v: :argument }, t1[:sources])
    assert_equal({ v: :argument }, t2[:sources])
    refute_same t1[:sources], t2[:sources]
  end

  def test_parent_forwards_arguments_to_two_prerequisites
    define_three_task_example

    Rake::Task["parent"].invoke("hello")

    parent = trace_entries_for("parent", :bind).last
    left   = trace_entries_for("left", :bind).last
    right  = trace_entries_for("right", :bind).last

    assert_equal({ msg: :argument }, parent[:sources])
    assert_equal({ msg: :forwarded, level: :default }, left[:sources])
    assert_equal({ msg: :forwarded, level: :default }, right[:sources])
  end

  def test_prerequisite_defaults_only_apply_when_value_missing
    define_three_task_example

    # Parent forwards only :msg; :level is missing in both
    # prerequisites, so their defaults kick in.
    Rake::Task["parent"].invoke("hello")
    assert_equal :default, trace_entries_for("left", :bind).last[:sources][:level]

    # When the value is supplied directly, the default must not
    # override it nor claim the source.
    left = Rake::Task["left"]
    left.clear
    Rake::Task.define_task("left", [:msg, :level]) do |_, args|
      args.with_defaults(level: "left-default")
    end
    seen = nil
    Rake::Task["left"].enhance do |_, args|
      seen = [args[:level], args.source_of(:level)]
    end
    left.reenable
    left.invoke("hi", "explicit")
    assert_equal ["explicit", :argument], seen
    assert_equal :argument, trace_entries_for("left", :bind).last[:sources][:level]
  end

  def test_already_invoked_task_records_skip_not_binding
    define_three_task_example

    parent = Rake::Task["parent"]
    parent.invoke("hello")
    parent.invoke("cached-second-call")

    entries = trace_entries_for("parent")
    assert_equal 2, entries.size

    assert_equal :bind, entries[0][:event]
    assert_equal({ msg: :argument }, entries[0][:sources])

    assert_equal :skipped, entries[1][:event]
    assert_equal :already_invoked, entries[1][:reason]
    refute entries[1].key?(:sources)

    # Semantics are unchanged: the task ran exactly once.
    assert parent.already_invoked
  end

  def test_trace_contains_only_names_and_sources_never_values
    define_three_task_example

    Rake::Task["parent"].invoke("top-secret-value")

    @app.argument_source_trace.each do |entry|
      refute_equal "top-secret-value", entry[:task]
      sources = entry[:sources] || {}
      sources.each do |name, source|
        assert_kind_of Symbol, name
        assert_include [:argument, :forwarded, :default], source
        refute_equal "top-secret-value", source
      end
    end
    assert_equal [:argument],
      trace_entries_for("parent", :bind).last[:sources].values
  end

  def test_argument_scope_is_restored_and_does_not_leak_into_next_call
    define_three_task_example

    Rake::Task["parent"].invoke("hello")
    assert_equal [], @app.current_argument_scope

    # A later direct invocation must see its own scope only: the
    # forwarded binding from the previous call must not leak through.
    left = Rake::Task["left"]
    left.reenable
    left.invoke("direct")
    assert_equal [], @app.current_argument_scope
    assert_equal :argument, trace_entries_for("left", :bind).last[:sources][:msg]
  end

  def test_argument_scope_is_restored_even_when_invocation_fails
    Rake::Task.define_task("boom", [:x]) { |_, _| raise "fail" }

    assert_raises(RuntimeError) { Rake::Task["boom"].invoke("1") }
    assert_equal [], @app.current_argument_scope
  end

  def test_argument_source_trace_is_isolated_per_application
    other_app = Rake::Application.new

    Rake::Task.define_task("lonely", [:x])
    Rake::Task["lonely"].invoke("1")

    refute_empty @app.argument_source_trace
    assert_equal [], other_app.argument_source_trace
  end
end
