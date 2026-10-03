# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeParameterBinding < Rake::TestCase # :nodoc:
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

  # A converter that counts how many times it is called.
  def counting_converter(counter, &converter)
    converter ||= ->(v) { Integer(v) }
    ->(v) {
      counter[:calls] += 1
      converter.call(v)
    }
  end

  def test_basic_binding_converts_raw_string
    task :t, [:count] do |tt, args|
      assert_equal 2, args[:count]
      assert_kind_of Integer, args[:count]
      assert_equal({ count: 2 }, args.to_hash)
    end
    parameter :t, :count, Integer
    t = Task[:t]
    t.invoke("2")
  end

  def test_binding_via_method_missing
    task :t, [:quantity] do |tt, args|
      assert_equal 2, args.quantity
      assert_equal 2, args[:quantity]
      assert_equal 2, args["quantity"]
    end
    parameter :t, :quantity, Integer
    Task[:t].invoke("2")
  end

  def test_empty_string_is_not_replaced_by_default
    task :t, [:count] do |tt, args|
      flunk "action should not run when conversion fails"
    end
    parameter :t, :count, Integer, default: 5
    assert_raises(Rake::ParameterBindingError) { Task[:t].invoke("") }
  end

  def test_default_only_fills_missing
    task :t, [:count] do |tt, args|
      assert_equal 5, args[:count]
    end
    parameter :t, :count, Integer, default: 5
    Task[:t].invoke
  end

  def test_default_factory_called_once_per_invocation
    counter = { calls: 0 }
    task :t, [:count] do |tt, args|
      assert_equal 5, args[:count]
    end
    parameter :t, :count, Integer,
              default: -> { counter[:calls] += 1; 5 }
    Task[:t].invoke
    assert_equal 1, counter[:calls]
    Task[:t].reenable
    Task[:t].invoke
    assert_equal 2, counter[:calls]
  end

  def test_same_converter_inherited_without_reconversion
    counter = { calls: 0 }
    converter = counting_converter(counter)
    task :pre, [:count] do |tt, args|
      assert_equal 2, args[:count]
    end
    parameter :pre, :count, converter
    task :t, [:count] => [:pre] do |tt, args|
      assert_equal 2, args[:count]
    end
    parameter :t, :count, converter
    Task[:t].invoke("2")
    assert_equal 1, counter[:calls]
  end

  def test_different_converter_triggers_reconversion
    counter = { calls: 0 }
    parent_converter = counting_converter(counter)
    child_converter = ->(v) { raise "cannot accept #{v.inspect}" }
    task :pre, [:count] do |tt, args|
      flunk "prereq action should not run"
    end
    parameter :pre, :count, child_converter
    task :t, [:count] => [:pre] do |tt, args|
      flunk "parent action should not run"
    end
    parameter :t, :count, parent_converter
    ex = assert_raises(Rake::ParameterBindingError) { Task[:t].invoke("2") }
    assert_match(/cannot convert parameter 'count' of task 'pre'/, ex.message)
    assert_equal "pre", ex.task_path
    assert_equal :count, ex.param_name
    assert_equal "2", ex.raw_value
    assert_equal 1, counter[:calls]
  end

  def test_conversion_failure_does_not_run_action
    ran = false
    task :t, [:count] do |tt, args|
      ran = true
    end
    parameter :t, :count, Integer
    assert_raises(Rake::ParameterBindingError) { Task[:t].invoke("abc") }
    refute ran
  end

  def test_conversion_failure_leaves_no_half_bound_values
    task :t, [:a, :b] do |tt, args|
      flunk "action should not run"
    end
    parameter :t, :a, Integer
    parameter :t, :b, Integer
    assert_raises(Rake::ParameterBindingError) { Task[:t].invoke("1", "bad") }
  end

  def test_required_param_missing_raises
    task :t, [:count] do |tt, args|
      flunk "action should not run"
    end
    parameter :t, :count, Integer
    assert_raises(Rake::ParameterMissing) { Task[:t].invoke }
  end

  def test_optional_param_without_default_is_nil
    task :t, [:count] do |tt, args|
      assert_nil args[:count]
    end
    parameter :t, :count, Integer, required: false
    Task[:t].invoke
  end

  def test_namespace_error_includes_task_path
    ns = namespace :ns do
      task :t, [:count] do |tt, args|
        flunk "action should not run"
      end
      parameter :t, :count, Integer
    end
    ex = assert_raises(Rake::ParameterBindingError) { ns[:t].invoke("abc") }
    assert_match(/task 'ns:t'/, ex.message)
    assert_equal "ns:t", ex.task_path
  end

  def test_namespace_parameter_lookup
    namespace :ns do
      task :t, [:count] do |tt, args|
        assert_equal 2, args[:count]
      end
      parameter :t, :count, Integer
    end
    Task["ns:t"].invoke("2")
  end

  def test_parent_arguments_not_modified_by_child_binding
    parent_args = nil
    task :pre, [:count] do |tt, args|
      assert_equal 2, args[:count]
    end
    parameter :pre, :count, Integer
    task :t, [:count] => [:pre] do |tt, args|
      parent_args = args
      assert_equal 2, args[:count]
    end
    parameter :t, :count, Integer
    Task[:t].invoke("2")
    assert_equal 2, parent_args[:count]
    assert_equal 2, parent_args[:count]
  end

  def test_raw_value_keeps_explicit_empty_string
    task :t, [:count] do |tt, args|
      assert_equal "", args.raw_value(:count)
    end
    parameter :t, :count, ->(v) { v }
    Task[:t].invoke("")
  end

  def test_raw_value_nil_when_missing
    task :t, [:count] do |tt, args|
      assert_nil args.raw_value(:count)
    end
    parameter :t, :count, ->(v) { v }, required: false
    Task[:t].invoke
  end

  def test_builtin_converters
    task :t, [:a, :b, :c, :d] do |tt, args|
      assert_kind_of Integer, args.a
      assert_kind_of Float, args.b
      assert_kind_of String, args.c
      assert_equal :sym, args.d
    end
    parameter :t, :a, Rake::Converters::INTEGER
    parameter :t, :b, Rake::Converters::FLOAT
    parameter :t, :c, Rake::Converters::STRING
    parameter :t, :d, Rake::Converters::SYMBOL
    Task[:t].invoke("1", "1.5", "x", "sym")
  end

  def test_parameter_dsl_returns_task
    task :t, [:count]
    result = parameter :t, :count, Integer
    assert_equal Task[:t], result
  end

  def test_declaring_parameter_adds_arg_name
    task :t
    parameter :t, :count, Integer
    assert_equal [:count], Task[:t].arg_names
  end

  def test_clear_removes_parameter_schema
    task :t, [:count] do |tt, args|
      flunk "action should not run"
    end
    parameter :t, :count, Integer
    assert Task[:t].has_parameter_schema?
    Task[:t].clear
    refute Task[:t].has_parameter_schema?
    Task[:t].invoke("abc")
  end
end
