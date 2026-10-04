# frozen_string_literal: true
#
# = ActionScope Demo
#
# This demo shows how Rake::Task.with_action temporarily replaces a task's
# action within a block, and how the original action and the previous invoke
# state are restored when the block exits (normally or via an exception).
#
# Run it with:
#
#   ruby -Ilib doc/action_scope_demo.rb
#
# The expected print order is:
#
#   1. original action
#   2. temporary action (inside the scope)
#   3. original action (restored after the scope)
#   4. nested temporary actions, restored in LIFO order
#   5. dependency actions, with their invoke state restored
#
# The key points:
#
# * Only the explicitly given full task name is affected.
# * Nested scopes are restored in LIFO order.
# * Exceptions inside the scope still restore the original state.
# * Dependency declarations are not deleted.
# * Tasks invoked during the temporary execution are not marked as completed
#   once the scope exits.
# * Each Rake::Application has its own isolated scope stack.

require_relative "../lib/rake"

include Rake::DSL

puts "=" * 60
puts "1. Original -> temporary -> original"
puts "=" * 60

task :foo do
  puts "  [original] foo"
end

puts "  -- before scope --"
Rake::Task[:foo].invoke

puts "  -- in scope --"
Rake::Task.with_action(:foo) do |scope|
  scope.action { puts "  [temporary] foo" }
  Rake::Task[:foo].invoke
end

puts "  -- after scope --"
Rake::Task[:foo].reenable
Rake::Task[:foo].invoke

puts
puts "=" * 60
puts "2. Nested scopes restore in LIFO order"
puts "=" * 60

task :bar do
  puts "  [original] bar"
end

Rake::Task.with_action(:bar) do |outer|
  outer.action { puts "  [outer temporary] bar" }
  Rake::Task[:bar].invoke

  Rake::Task.with_action(:bar) do |inner|
    inner.action { puts "  [inner temporary] bar" }
    Rake::Task[:bar].invoke
  end

  # inner scope restored to the outer temporary action
  puts "  -- after inner scope (outer temporary restored) --"
  Rake::Task[:bar].reenable
  Rake::Task[:bar].invoke
end

# outer scope restored to the original action
puts "  -- after outer scope (original restored) --"
Rake::Task[:bar].reenable
Rake::Task[:bar].invoke

puts
puts "=" * 60
puts "3. Exception inside the scope still restores"
puts "=" * 60

task :baz do
  puts "  [original] baz"
end

begin
  Rake::Task.with_action(:baz) do |scope|
    scope.action { puts "  [temporary] baz" }
    raise "something went wrong"
  end
rescue RuntimeError => e
  puts "  -- rescued: #{e.message} --"
end

puts "  -- after exception (original restored) --"
Rake::Task[:baz].reenable
Rake::Task[:baz].invoke

puts
puts "=" * 60
puts "4. Dependencies are preserved and their invoke state restored"
puts "=" * 60

task app: [:dependency] do
  puts "  [original] app"
end
task :dependency do
  puts "  dependency"
end

Rake::Task.with_action(:app) do |scope|
  scope.action { puts "  [temporary] app" }
  Rake::Task[:app].invoke
end

puts "  -- after scope (dependency not marked completed) --"
Rake::Task[:app].reenable
Rake::Task[:app].invoke

puts
puts "=" * 60
puts "5. Applications are isolated from each other"
puts "=" * 60

app1 = Rake::Application.new
app2 = Rake::Application.new

Rake.with_application(app1) do
  task :shared do
    puts "  [app1 original] shared"
  end
end

Rake.with_application(app2) do
  task :shared do
    puts "  [app2 original] shared"
  end
end

puts "  -- app1 scope --"
Rake.with_application(app1) do
  Rake::Task.with_action(:shared) do |scope|
    scope.action { puts "  [app1 temporary] shared" }
    Rake::Task[:shared].invoke
  end
  Rake::Task[:shared].reenable
  Rake::Task[:shared].invoke
end

puts "  -- app2 unaffected --"
Rake.with_application(app2) do
  Rake::Task[:shared].reenable
  Rake::Task[:shared].invoke
end

puts
puts "Demo complete."
