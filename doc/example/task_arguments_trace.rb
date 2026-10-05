# frozen_string_literal: true

# Three-task example demonstrating explicit TaskArguments source tracking.
#
# Run with:
#   ruby -Ilib doc/example/task_arguments_trace.rb
#
# The example defines a parent task that passes arguments to two
# dependencies.  Each dependency has a default that only applies when
# the parent does not supply a value.  The trace shows the real scope
# of every argument value (actual, default, or forwarded) without
# inspecting the final value.

require "rake"

Rake::Task.clear
Rake.application = Rake::Application.new

task :child1, [:a, :c] do |t, args|
  args.with_defaults(c: "default_c")
  puts "child1 trace: #{args.trace.inspect}"
end

task :child2, [:b, :d] do |t, args|
  args.with_defaults(d: "default_d")
  puts "child2 trace: #{args.trace.inspect}"
end

task :parent, [:a, :b] => [:child1, :child2] do |t, args|
  puts "parent trace: #{args.trace.inspect}"
end

puts "=== First invocation (all tasks execute) ==="
Rake::Task[:parent].invoke("x", "y")

puts ""
puts "=== Second invocation (all tasks skipped) ==="
Rake::Task[:parent].invoke("x", "y")
puts "parent bound: #{Rake::Task[:parent].last_args.bound}"
puts "child1 bound: #{Rake::Task[:child1].last_args.bound}"
puts "child2 bound: #{Rake::Task[:child2].last_args.bound}"
