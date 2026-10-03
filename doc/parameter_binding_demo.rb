# frozen_string_literal: true
#
# Demo: typed parameter binding for Rake tasks.
#
# Run with:
#   ruby -Ilib doc/parameter_binding_demo.rb
#
# This demo shows how to declare typed parameters on a task, how the raw
# string values are bound (converted) before the action runs, how values
# are inherited by prerequisites without converting twice, and how a
# failed conversion is reported with the task path.
#
# It prints the bound values and the conversion count for each scenario.

require "rake"
include Rake

# A converter that counts how many times it is called.
def counting_converter(counter, &converter)
  converter ||= ->(v) { Integer(v) }
  ->(v) {
    counter[:calls] += 1
    converter.call(v)
  }
end

def section(title)
  puts
  puts "== #{title} =="
end

# ---------------------------------------------------------------------------
# 1. Basic binding: a raw string is converted to a typed value.
# ---------------------------------------------------------------------------
section "1. Basic binding (string -> Integer)"

counter = { calls: 0 }
task :build, [:count] do |t, args|
  puts "  build: count=#{args[:count].inspect} (#{args[:count].class})"
end
parameter :build, :count, counting_converter(counter)

Rake::Task[:build].invoke("2")
puts "  conversion count: #{counter[:calls]}"

# ---------------------------------------------------------------------------
# 2. Parameter inheritance: a prerequisite with the *same* converter reuses
#    the already-bound value without converting again.
# ---------------------------------------------------------------------------
section "2. Inheritance (same converter -> no reconversion)"

counter = { calls: 0 }
converter = counting_converter(counter)
task :compile, [:count] do |t, args|
  puts "  compile: count=#{args[:count].inspect} (#{args[:count].class})"
end
parameter :compile, :count, converter
task :build2, [:count] => [:compile] do |t, args|
  puts "  build2: count=#{args[:count].inspect} (#{args[:count].class})"
end
parameter :build2, :count, converter

Rake::Task[:build2].invoke("3")
puts "  conversion count: #{counter[:calls]} (expected 1)"

# ---------------------------------------------------------------------------
# 3. Different converter: the prerequisite re-checks the original raw text
#    with its own converter.  A failure is reported with the task path.
# ---------------------------------------------------------------------------
section "3. Different converter -> reconversion error with task path"

counter = { calls: 0 }
parent_converter = counting_converter(counter)
child_converter = ->(v) { raise "cannot accept #{v.inspect}" }
task :compile2, [:count] do |t, args|
  puts "  compile2: count=#{args[:count].inspect}"
end
parameter :compile2, :count, child_converter
task :build3, [:count] => [:compile2] do |t, args|
  puts "  build3: count=#{args[:count].inspect}"
end
parameter :build3, :count, parent_converter

begin
  Rake::Task[:build3].invoke("4")
rescue Rake::ParameterBindingError => e
  puts "  error: #{e.message}"
  puts "  task path: #{e.task_path}"
end
puts "  conversion count: #{counter[:calls]} (parent converted once)"

# ---------------------------------------------------------------------------
# 4. Empty string is not replaced by the default; it goes through the
#    converter (and fails here because Integer("") is invalid).
# ---------------------------------------------------------------------------
section "4. Empty string is not replaced by the default"

task :build4, [:count] do |t, args|
  puts "  build4: count=#{args[:count].inspect}"
end
parameter :build4, :count, Integer, default: 5

begin
  Rake::Task[:build4].invoke("")
rescue Rake::ParameterBindingError => e
  puts "  error: #{e.message}"
  puts "  (the default 5 was NOT used for the explicit empty string)"
end

# ---------------------------------------------------------------------------
# 5. Default only fills missing values.
# ---------------------------------------------------------------------------
section "5. Default only fills missing values"

task :build5, [:count] do |t, args|
  puts "  build5: count=#{args[:count].inspect} (#{args[:count].class})"
end
parameter :build5, :count, Integer, default: 5

Rake::Task[:build5].invoke        # no value -> default
Rake::Task[:build5].reenable
Rake::Task[:build5].invoke("7")   # explicit value -> no default

# ---------------------------------------------------------------------------
# 6. Default factory is called at most once per invocation.
# ---------------------------------------------------------------------------
section "6. Default factory called once per invocation"

counter = { calls: 0 }
task :build6, [:count] do |t, args|
  puts "  build6: count=#{args[:count].inspect}"
end
parameter :build6, :count, Integer,
          default: -> { counter[:calls] += 1; 5 }

Rake::Task[:build6].invoke
Rake::Task[:build6].reenable
Rake::Task[:build6].invoke
puts "  factory calls: #{counter[:calls]} (one per invocation)"

# ---------------------------------------------------------------------------
# 7. Namespace: the error includes the full task path.
# ---------------------------------------------------------------------------
section "7. Namespace error includes task path"

ns = namespace :ns do
  task :build7, [:count] do |t, args|
    puts "  ns:build7: count=#{args[:count].inspect}"
  end
  parameter :build7, :count, Integer
end

begin
  ns[:build7].invoke("abc")
rescue Rake::ParameterBindingError => e
  puts "  error: #{e.message}"
end

puts
puts "Done."
