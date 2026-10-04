# frozen_string_literal: true
# Demo of the explicit argument binding layer.
#
# Run from the repository root:
#
#   ruby -Ilib doc/example/argument_binding_demo.rb
#
# It prints the bound values seen by each task action and the number
# of times each converter actually ran.

require "rake"
include Rake::DSL

Rake.application = Rake::Application.new

# A converter that counts how often it runs.
integer_conversions = 0
counting_integer = ->(s) { integer_conversions += 1; Integer(s) }

default_factory_calls = 0
tag_factory = -> { default_factory_calls += 1; "untagged" }

# --- A child task with typed arguments -------------------------------
task :child, [:count, :tag]
Rake::Task[:child].bind_argument :count, convert: counting_integer, required: true
Rake::Task[:child].bind_argument :tag,   default: tag_factory
Rake::Task[:child].enhance do |_, args|
  puts "child:  count=#{args[:count].inspect} (#{args[:count].class}), "        "tag=#{args[:tag].inspect}"
end

# --- A parent that passes its already bound count down ---------------
task :parent, [:count] => [:child]
Rake::Task[:parent].bind_argument :count, convert: counting_integer
Rake::Task[:parent].enhance do |_, args|
  puts "parent: count=#{args[:count].inspect} (#{args[:count].class})"
end

puts "== parent count=2 with a compatible child declaration =="
Rake::Task[:parent].invoke("2")
puts "integer conversions: #{integer_conversions} (expected 1: "      "the child reuses the parent bound value)"
puts "default factory calls: #{default_factory_calls} (expected 1: "      "tag was missing, so the default filled it)"

# --- Explicit empty string is not swapped for the default ------------
puts
puts "== explicit empty string vs missing =="
Rake.application = Rake::Application.new
empty_demo = Rake::Task.define_task(:echo, [:tag])
empty_demo.bind_argument :tag, as: :string, default: tag_factory
empty_demo.enhance { |_, args| puts "echo:   tag=#{args[:tag].inspect}" }
empty_demo.invoke("")   # explicit empty string stays ""
empty_demo.reenable
empty_demo.invoke       # missing argument gets the default
puts "default factory calls: #{default_factory_calls} (expected 2 total)"

# --- A child declaring a different converter re-validates ------------
puts
puts "== child with a different declaration re-validates the raw text =="
Rake.application = Rake::Application.new
Rake::Task.define_task(:child2, [:count]) do |_, args|
  puts "child2: count=#{args[:count].inspect}"
end.bind_argument(:count, convert: ->(s) {
  raise "must look like n:<digits>" unless s =~ /\An:\d+\z/
  s
})
Rake::Task.define_task(:parent2, [:count] => [:child2])
  .bind_argument(:count, convert: counting_integer)
begin
  Rake::Task[:parent2].invoke("2")
rescue Rake::ArgumentBindingError => ex
  puts "raised: #{ex.message}"
end
puts "integer conversions: #{integer_conversions} (expected 2 total: "      "child2 re-validated the raw text, not re-ran the parent converter)"
