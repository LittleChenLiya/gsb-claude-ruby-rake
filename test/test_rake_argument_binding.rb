# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeArgumentBinding < Rake::TestCase # :nodoc:
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

  def counting_converter(counter)
    ->(s) { counter << s; Integer(s) }
  end

  def test_bound_value_is_converted_before_action_runs
    t = task(:t, [:count])
    t.bind_argument :count, as: :integer
    seen = nil
    t.enhance { |_, args| seen = args[:count] }
    t.invoke("2")
    assert_equal 2, seen
  end

  def test_task_without_binding_keeps_string_interface
    t = task(:t, [:count])
    seen = nil
    t.enhance { |_, args| seen = args[:count] }
    t.invoke("2")
    assert_equal "2", seen
  end

  def test_parent_bound_value_is_not_reconverted_by_compatible_child
    conversions = []
    converter = counting_converter(conversions)

    child = task(:child, [:count])
    child.bind_argument :count, convert: converter
    child_seen = nil
    child.enhance { |_, args| child_seen = args[:count] }

    parent = task(:parent, [:count] => [:child])
    parent.bind_argument :count, convert: converter

    parent.invoke("2")

    assert_equal 2, child_seen
    assert_equal ["2"], conversions,
      "compatible declarations must reuse the parent bound value (converted once)"
  end

  def test_child_with_different_declaration_revalidates_raw_text
    child = task(:child, [:count])
    child.bind_argument :count, convert: ->(s) {
      raise "bad prefix" unless s.start_with?("n:")
      s
    }
    child_ran = false
    child.enhance { |_, _| child_ran = true }

    parent = task(:parent, [:count] => [:child])
    parent.bind_argument :count, as: :integer

    ex = assert_raises(Rake::ArgumentBindingError) { parent.invoke("2") }
    assert_equal "child", ex.task_name
    assert_equal :count, ex.argument_name
    assert_match(/task "child"/, ex.message)
    assert_equal false, child_ran
  end

  def test_error_carries_full_namespace_path
    namespace :ns do
      t = task(:inner, [:count])
      t.bind_argument :count, as: :integer
    end
    ex = assert_raises(Rake::ArgumentBindingError) do
      Task["ns:inner"].invoke("nope")
    end
    assert_equal "ns:inner", ex.task_name
    assert_match(/"ns:inner"/, ex.message)
  end

  def test_binding_works_inside_namespace
    seen = nil
    namespace :ns do
      t = task(:inner, [:count])
      t.bind_argument :count, as: :integer
      t.enhance { |_, args| seen = args[:count] }
    end
    Task["ns:inner"].invoke("3")
    assert_equal 3, seen
  end

  def test_conversion_failure_does_not_execute_action
    ran = false
    t = task(:t, [:count])
    t.bind_argument :count, as: :integer
    t.enhance { |_, _| ran = true }
    assert_raises(Rake::ArgumentBindingError) { t.invoke("x") }
    assert_equal false, ran
  end

  def test_conversion_failure_leaves_no_half_bound_values
    original = TaskArguments.new([:a, :b], ["1", "bad"])
    binding = ArgumentBinding.new
    binding.add :a, as: :integer
    binding.add :b, as: :integer

    assert_raises(ArgumentBindingError) { binding.bind("t", original) }

    assert_equal({ a: "1", b: "bad" }, original.to_hash)
    assert_equal false, original.bound?(:a)
    assert_equal false, original.bound?(:b)
  end

  def test_binding_does_not_modify_parent_arguments
    parent_args = TaskArguments.new([:count], ["2"])
    child_args = parent_args.new_scope([:count])

    binding = ArgumentBinding.new
    binding.add :count, as: :integer
    bound = binding.bind("child", child_args)

    assert_equal 2, bound[:count]
    assert_equal "2", parent_args[:count]
    assert_equal false, parent_args.bound?(:count)
    assert_equal false, child_args.bound?(:count)
  end

  def test_explicit_empty_string_is_not_replaced_by_default
    t = task(:t, [:tag])
    t.bind_argument :tag, as: :string, default: -> { "DEF" }
    seen = :unset
    t.enhance { |_, args| seen = args[:tag] }
    t.invoke("")
    assert_equal "", seen
  end

  def test_default_fills_only_missing_arguments
    t = task(:t, [:tag])
    t.bind_argument :tag, as: :string, default: -> { "DEF" }
    seen = nil
    t.enhance { |_, args| seen = args[:tag] }
    t.invoke
    assert_equal "DEF", seen
  end

  def test_default_factory_called_at_most_once_per_invocation
    calls = 0
    factory = -> { calls += 1; "DEF" }
    t = task(:t, [:tag])
    t.bind_argument :tag, default: factory
    t.enhance { |_, _| }

    t.invoke
    assert_equal 1, calls

    t.reenable
    t.invoke
    assert_equal 2, calls
  end

  def test_default_factory_not_called_when_value_supplied
    calls = 0
    t = task(:t, [:tag])
    t.bind_argument :tag, default: -> { calls += 1; "DEF" }
    t.enhance { |_, _| }
    t.invoke("given")
    assert_equal 0, calls
  end

  def test_missing_required_argument_raises_with_task_path
    t = task(:t, [:count])
    t.bind_argument :count, as: :integer, required: true
    ex = assert_raises(Rake::ArgumentBindingError) { t.invoke }
    assert_equal "t", ex.task_name
    assert_match(/required/, ex.message)
  end

  def test_optional_missing_argument_stays_absent
    t = task(:t, [:maybe])
    t.bind_argument :maybe, as: :string
    seen = :unset
    t.enhance { |_, args| seen = args[:maybe] }
    t.invoke
    assert_nil seen
  end

  def test_bind_args_hash_form
    t = task(:t, [:count, :tag])
    t.bind_args(
      count: { as: :integer, required: true },
      tag:   { default: -> { "x" } }
    )
    seen = nil
    t.enhance { |_, args| seen = [args[:count], args[:tag]] }
    t.invoke("5")
    assert_equal [5, "x"], seen
  end

  def test_clear_args_removes_binding
    t = task(:t, [:count])
    t.bind_argument :count, as: :integer
    t.clear_args
    assert_nil t.arg_binding
    seen = nil
    t.enhance { |_, args| seen = args.extras }
    t.invoke("2")
    assert_equal ["2"], seen
  end

  def test_registered_converters
    assert_equal 1, ArgumentBinding::CONVERTERS[:integer].call("1")
    assert_equal 1.5, ArgumentBinding::CONVERTERS[:float].call("1.5")
    assert_equal :sym, ArgumentBinding::CONVERTERS[:symbol].call("sym")
    assert_equal true, ArgumentBinding::CONVERTERS[:boolean].call("yes")
    assert_equal false, ArgumentBinding::CONVERTERS[:boolean].call("off")
    assert_raises(ArgumentError) do
      ArgumentBinding::CONVERTERS[:boolean].call("maybe")
    end
  end

  def test_bound_entry_visible_in_child_scope
    parent_args = TaskArguments.new([:count], ["2"])
    binding = ArgumentBinding.new
    binding.add :count, as: :integer
    bound_parent = binding.bind("parent", parent_args)

    child_args = bound_parent.new_scope([:count])
    assert_equal true, child_args.bound?(:count)
    assert_equal 2, child_args[:count]
    assert_equal "2", child_args.bound_entry(:count).raw
  end
end
