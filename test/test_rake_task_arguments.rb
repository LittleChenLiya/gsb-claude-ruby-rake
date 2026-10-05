# frozen_string_literal: true
require File.expand_path("../helper", __FILE__)

class TestRakeTaskArguments < Rake::TestCase # :nodoc:
  def teardown
    ENV.delete("rev")
    ENV.delete("VER")

    super
  end

  def test_empty_arg_list_is_empty
    ta = Rake::TaskArguments.new([], [])
    assert_equal({}, ta.to_hash)
  end

  def test_multiple_values_in_args
    ta = Rake::TaskArguments.new([:a, :b, :c], [:one, :two, :three])
    assert_equal({ a: :one, b: :two, c: :three }, ta.to_hash)
  end

  def test_blank_values_in_args
    ta = Rake::TaskArguments.new([:a, :b, :c], ["", :two, ""])
    assert_equal({ b: :two }, ta.to_hash)
  end

  def test_has_key
    ta = Rake::TaskArguments.new([:a], [:one])
    assert(ta.has_key?(:a))
    assert(ta.key?(:a))
    refute(ta.has_key?(:b))
    refute(ta.key?(:b))
  end

  def test_fetch
    ta = Rake::TaskArguments.new([:one], [1])
    assert_equal 1, ta.fetch(:one)
    assert_equal 2, ta.fetch(:two) { 2 }
    assert_raises(KeyError) { ta.fetch(:three) }
  end

  def test_to_s
    ta = Rake::TaskArguments.new([:a, :b, :c], [1, 2, 3])
    expectation = "#<Rake::TaskArguments a: 1, b: 2, c: 3>"
    assert_equal expectation, ta.to_s
    assert_equal expectation, ta.inspect
  end

  def test_to_hash
    ta = Rake::TaskArguments.new([:one], [1])
    h = ta.to_hash
    h[:one] = 0
    assert_equal 1, ta.fetch(:one)
    assert_equal 0,  h.fetch(:one)
  end

  def test_deconstruct_keys
    omit "No stable pattern matching until Ruby 3.1 (testing #{RUBY_VERSION})" if RUBY_VERSION < "3.1"

    ta = Rake::TaskArguments.new([:a, :b, :c], [1, 2, 3])
    assert_equal({ a: 1, b: 2, c: 3 }, ta.deconstruct_keys(nil))
    assert_equal({ a: 1, b: 2 },       ta.deconstruct_keys([:a, :b]))
  end

  def test_enumerable_behavior
    ta = Rake::TaskArguments.new([:a, :b, :c], [1, 2, 3])
    assert_equal [10, 20, 30], ta.map { |k, v| v * 10 }.sort
  end

  def test_named_args
    ta = Rake::TaskArguments.new(["aa", "bb"], [1, 2])
    assert_equal 1, ta.aa
    assert_equal 1, ta[:aa]
    assert_equal 1, ta["aa"]
    assert_equal 2, ta.bb
    assert_nil ta.cc
  end

  def test_args_knows_its_names
    ta = Rake::TaskArguments.new(["aa", "bb"], [1, 2])
    assert_equal ["aa", "bb"], ta.names
  end

  def test_extra_names_are_nil
    ta = Rake::TaskArguments.new(["aa", "bb", "cc"], [1, 2])
    assert_nil ta.cc
  end

  def test_args_do_not_reference_env_values
    ta = Rake::TaskArguments.new(["aa"], [1])
    ENV["rev"] = "1.2"
    ENV["VER"] = "2.3"
    assert_nil ta.rev
    assert_nil ta.ver
  end

  def test_creating_new_argument_scopes
    parent = Rake::TaskArguments.new(["p"], [1])
    child = parent.new_scope(["c", "p"])
    assert_equal({ p: 1 }, child.to_hash)
    assert_equal 1, child.p
    assert_equal 1, child["p"]
    assert_equal 1, child[:p]
    assert_nil child.c
  end

  def test_child_hides_parent_arg_names
    parent = Rake::TaskArguments.new(["aa"], [1])
    child = Rake::TaskArguments.new(["aa"], [2], parent)
    assert_equal 2, child.aa
  end

  def test_default_arguments_values_can_be_merged
    ta = Rake::TaskArguments.new(["aa", "bb"], [nil, "original_val"])
    ta.with_defaults(aa: "default_val")
    assert_equal "default_val", ta[:aa]
    assert_equal "original_val", ta[:bb]
  end

  def test_default_arguments_that_dont_match_names_are_ignored
    ta = Rake::TaskArguments.new(["aa", "bb"], [nil, "original_val"])
    ta.with_defaults("cc" => "default_val")
    assert_nil ta[:cc]
  end

  def test_all_and_extra_arguments_without_named_arguments
    app = Rake::Application.new
    _, args = app.parse_task_string("task[1,two,more]")
    ta = Rake::TaskArguments.new([], args)
    assert_equal [], ta.names
    assert_equal ["1", "two", "more"], ta.to_a
    assert_equal ["1", "two", "more"], ta.extras
  end

  def test_all_and_extra_arguments_with_named_arguments
    app = Rake::Application.new
    _, args = app.parse_task_string("task[1,two,more,still more]")
    ta = Rake::TaskArguments.new([:first, :second], args)
    assert_equal [:first, :second], ta.names
    assert_equal "1", ta[:first]
    assert_equal "two", ta[:second]
    assert_equal ["1", "two", "more", "still more"], ta.to_a
    assert_equal ["more", "still more"], ta.extras
  end

  def test_extra_args_with_less_than_named_arguments
    app = Rake::Application.new
    _, args = app.parse_task_string("task[1,two]")
    ta = Rake::TaskArguments.new([:first, :second, :third], args)
    assert_equal [:first, :second, :third], ta.names
    assert_equal "1", ta[:first]
    assert_equal "two", ta[:second]
    assert_nil ta[:third]
    assert_equal ["1", "two"], ta.to_a
    assert_equal [], ta.extras
  end

  def test_trace_records_actual_sources_with_scope
    ta = Rake::TaskArguments.new([:a, :b], [1, 2], nil, "parent")
    assert_equal(
      { a: { kind: :actual, scope: "parent" },
        b: { kind: :actual, scope: "parent" } },
      ta.trace
    )
  end

  def test_trace_records_default_sources_with_scope
    ta = Rake::TaskArguments.new([:a, :b], [1, nil], nil, "child")
    ta.with_defaults(b: "default_b")
    assert_equal(
      { a: { kind: :actual, scope: "child" },
        b: { kind: :default, scope: "child" } },
      ta.trace
    )
  end

  def test_trace_records_forwarded_sources_with_parent_scope
    parent = Rake::TaskArguments.new([:a, :b], [1, 2], nil, "parent")
    child = parent.new_scope([:a, :c], scope: "child")
    assert_equal(
      { a: { kind: :forwarded, scope: "parent" } },
      child.trace
    )
  end

  def test_trace_forwarded_then_default
    parent = Rake::TaskArguments.new([:a], [1], nil, "parent")
    child = parent.new_scope([:a, :c], scope: "child")
    child.with_defaults(c: "default_c")
    assert_equal(
      { a: { kind: :forwarded, scope: "parent" },
        c: { kind: :default, scope: "child" } },
      child.trace
    )
  end

  def test_trace_does_not_include_values
    ta = Rake::TaskArguments.new([:secret], ["s3cr3t"], nil, "task")
    trace = ta.trace
    assert_equal({ secret: { kind: :actual, scope: "task" } }, trace)
    refute_includes trace.inspect, "s3cr3t"
  end

  def test_bound_defaults_to_false
    ta = Rake::TaskArguments.new([:a], [1], nil, "task")
    assert_equal false, ta.bound
  end

  def test_bound_can_be_set_and_reset
    ta = Rake::TaskArguments.new([:a], [1], nil, "task")
    ta.bound = true
    assert_equal true, ta.bound
    ta.bound = false
    assert_equal false, ta.bound
  end

  def test_same_name_arguments_are_independent_across_scopes
    parent = Rake::TaskArguments.new([:a], [1], nil, "parent")
    child1 = parent.new_scope([:a], scope: "child1")
    child2 = parent.new_scope([:a], scope: "child2")
    child1.with_defaults(a: "default1")
    child2.with_defaults(a: "default2")
    assert_equal({ kind: :forwarded, scope: "parent" }, child1.trace[:a])
    assert_equal({ kind: :forwarded, scope: "parent" }, child2.trace[:a])
    assert_equal 1, child1[:a]
    assert_equal 1, child2[:a]
  end

  def test_default_only_applied_when_value_missing
    ta = Rake::TaskArguments.new([:a, :b], [1, nil], nil, "task")
    ta.with_defaults(a: "default_a", b: "default_b")
    assert_equal 1, ta[:a]
    assert_equal "default_b", ta[:b]
    assert_equal(
      { a: { kind: :actual, scope: "task" },
        b: { kind: :default, scope: "task" } },
      ta.trace
    )
  end

  def test_new_scope_without_scope_uses_parent_scope
    parent = Rake::TaskArguments.new([:a], [1], nil, "parent")
    child = parent.new_scope([:a])
    assert_equal "parent", child.scope
  end

  def test_new_scope_with_scope_overrides_parent_scope
    parent = Rake::TaskArguments.new([:a], [1], nil, "parent")
    child = parent.new_scope([:a], scope: "child")
    assert_equal "child", child.scope
  end

end
