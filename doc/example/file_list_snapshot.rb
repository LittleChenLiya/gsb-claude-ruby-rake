# frozen_string_literal: true

# Example: Rake::FileList#snapshot
#
# A FileList is lazy: its glob patterns are only expanded and filtered the
# first time the list is used, so reports taken at different times can
# disagree as files appear or exclude rules change. FileList#snapshot gives
# you an explicit entry point that resolves the list once and records where
# every path came from.
#
# Run with:
#
#   ruby -Ilib doc/example/file_list_snapshot.rb
#
# The script builds its demo files inside a small temporary directory and
# removes them afterwards.

require "fileutils"
require "tmpdir"
require "rake"

Dir.mktmpdir("file_list_snapshot_example") do |dir|
  Dir.chdir(dir) do
    File.write("a.rb", "# a")
    File.write("b.rb", "# b")

    puts "== building the lazy file list =="
    file_list = Rake::FileList["a.rb", "*.rb"].exclude("b.rb")
    puts "pending? #{file_list.instance_variable_get(:@pending)} (still lazy)"

    puts
    puts "== taking a snapshot =="
    snap = file_list.snapshot
    puts "pending? #{file_list.instance_variable_get(:@pending)} (still lazy)"

    snap.each do |entry|
      sources = entry.include_sources.map do |source|
        "#{source.kind}(#{source.pattern})"
      end.join(", ")
      verdict =
        if entry.included?
          "kept"
        else
          "removed by #{entry.excluded_by}"
        end
      puts "#{entry.path}: sources=[#{sources}] -> #{verdict}"
    end

    puts
    puts "kept paths: #{snap.paths.inspect}"

    puts
    puts "== creating c.rb after the snapshot was taken =="
    File.write("c.rb", "# c")
    puts "snapshot paths stay: #{snap.paths.inspect}"
    puts "snapshot knows c.rb? #{!snap["c.rb"].nil?}"
    puts "the lazy list now resolves to: #{file_list.to_a.inspect}"
  end
end
