# frozen_string_literal: true

# Demo: run a diamond dependency graph in two independent invocation
# sessions and watch the execution log and run counts.
#
# Run from the rake repository root:
#
#   ruby -Ilib doc/example/invocation_session_demo.rb

require "rake"

Rake.application = Rake::Application.new
include Rake::DSL

$mutex = Mutex.new
$counts = Hash.new(0)
$log = []

def record(name)
  $mutex.synchronize do
    $counts[name] += 1
    $log << format("[%<time>0.3f] run %<name>s (#%<count>d)",
                   time: Time.now.to_f - $started,
                   name: name,
                   count: $counts[name])
  end
end

# Diamond: top => left, right => base
task :base do
  record("base")
  sleep 0.05 # make the concurrent overlap visible
end
task left: [:base]  do record("left") end
task right: [:base] do record("right") end
multitask top: [:left, :right]

$started = Time.now.to_f

puts "== Session 1 (multitask diamond) =="
session1 = Rake.application.invocation_session
session1.invoke(:top)
session1.invoke(:top) # already invoked in this session: no-op
puts $log.join("\n")
puts "counts after session 1: #{$counts.inspect}"

puts
puts "== Session 2 (independent) =="
$log.clear
session2 = Rake.application.invocation_session
session2.invoke(:top)
puts $log.join("\n")
puts "counts after session 2: #{$counts.inspect}"

puts
puts "== Failure isolation =="
task :fragile do
  record("fragile")
  raise "fragile failed" if $counts["fragile"] == 1
end
task deploy: [:fragile] do record("deploy") end

begin
  session1.invoke(:deploy)
rescue => ex
  puts "session 1 raised: #{ex.message}"
end
begin
  session1.invoke(:deploy) # failure is remembered, not re-run
rescue => ex
  puts "session 1 raised again (no re-run): #{ex.message}"
end

session3 = Rake.application.invocation_session
session3.invoke(:deploy) # fresh session is not polluted by session 1
puts "session 3 ran deploy successfully"
puts "final counts: #{$counts.inspect}"

Rake.application.thread_pool.join
