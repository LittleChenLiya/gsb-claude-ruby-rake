# frozen_string_literal: true
#
# Demo: temporarily replacing a task's action inside a scope.
#
# Run from the repository root:
#
#   ruby -I lib demo/temporary_action.rb
#
# What it shows (see the expected output at the bottom):
#
#   1. Before the scope, the task runs its ORIGINAL action.
#   2. Inside `with_temporary_action`, the SAME task runs the
#      TEMPORARY action instead.  Prerequisites are untouched and
#      still run first.
#   3. The invocation done inside the scope does NOT mark the task as
#      invoked for the outside world: the invoke state is restored on
#      scope exit.
#   4. After the scope, the ORIGINAL action is back, with no
#      `reenable` needed.
#   5. Nested overrides restore in LIFO order, and an exception
#      raised in an inner scope still restores the outer override.
#   6. A second Rake::Application with a same-named task is not
#      affected.

require "rake"

app = Rake::Application.new
Rake.application = app

include Rake::DSL

task :prepare do
  puts "prepare (prerequisite)"
end

task build: [:prepare] do
  puts "original action"
end

puts "== 1. before the scope =="
Rake::Task["build"].invoke
Rake::Task["build"].reenable
Rake::Task["prepare"].reenable

puts "== 2/3. inside the scope (temporary action, prereqs intact) =="
app.with_temporary_action("build", ->(*) { puts "temporary action" }) do
  Rake::Task["build"].invoke
  puts "already_invoked inside scope: #{Rake::Task['build'].already_invoked}"
end

puts "== 4. after the scope (original action, state restored) =="
puts "already_invoked after scope: #{Rake::Task['build'].already_invoked}"
Rake::Task["build"].invoke

puts "== 5. nested scopes restore LIFO, exceptions are safe =="
Rake::Task["build"].reenable
app.with_temporary_action("build", ->(*) { puts "outer temporary" }) do
  Rake::Task["build"].invoke
  begin
    app.with_temporary_action("build", ->(*) { puts "inner temporary" }) do
      Rake::Task["build"].reenable
      Rake::Task["build"].invoke
      raise "boom"
    end
  rescue RuntimeError => ex
    puts "rescued: #{ex.message}"
  end
  Rake::Task["build"].reenable
  Rake::Task["build"].invoke # outer temporary action is still in place
end
Rake::Task["build"].invoke   # original action restored

puts "== 6. another application is isolated =="
other = Rake::Application.new
Rake.application = other
task(:build) { puts "other app original" }
app.with_temporary_action("build", ->(*) { puts "should not leak" }) do
  other["build"].invoke
end

# Expected output:
#
#   == 1. before the scope ==
#   prepare (prerequisite)
#   original action
#   == 2/3. inside the scope (temporary action, prereqs intact) ==
#   prepare (prerequisite)
#   temporary action
#   already_invoked inside scope: true
#   == 4. after the scope (original action, state restored) ==
#   already_invoked after scope: false
#   original action
#   == 5. nested scopes restore LIFO, exceptions are safe ==
#   outer temporary
#   inner temporary
#   rescued: boom
#   outer temporary
#   original action
#   == 6. another application is isolated ==
#   other app original
