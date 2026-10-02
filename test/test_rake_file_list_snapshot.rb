# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rake"
require "tmpdir"
require "fileutils"

class TestRakeFileListSnapshot < Minitest::Test
  # A tiny temporary working directory created and removed for every test.
  def with_files(files)
    Dir.mktmpdir("rake_file_list_snapshot_", tmp_root) do |dir|
      Dir.chdir(dir) do
        files.each do |name, contents|
          FileUtils.mkdir_p(File.dirname(name)) unless File.dirname(name) == "."
          File.write(name, contents)
        end
        yield dir
      end
    end
  end

  # Keep every temporary file on the current drive; honor TMPDIR/TMP/TEMP
  # when they point somewhere usable.
  def tmp_root
    [ENV["TMPDIR"], ENV["TMP"], ENV["TEMP"]].find { |d| d && File.directory?(d) }
  end

  def source_kinds(entry)
    entry.include_sources.map(&:kind)
  end

  def source_patterns(entry)
    entry.include_sources.map(&:pattern)
  end

  def test_returns_a_snapshot
    with_files("a.rb" => "") do
      snap = Rake::FileList["*.rb"].snapshot
      assert_kind_of Rake::FileList::Snapshot, snap
      assert_equal ["a.rb"], snap.paths
    end
  end

  def test_explicit_and_glob_sources_are_recorded_separately
    with_files("a.rb" => "", "b.rb" => "") do
      snap = Rake::FileList["a.rb", "*.rb"].exclude("b.rb").snapshot
      entry = snap["a.rb"]

      assert_equal ["a.rb"], snap.paths
      assert_equal 2, entry.include_sources.size
      assert_equal [:explicit, :glob], source_kinds(entry)
      assert_equal ["a.rb", "*.rb"], source_patterns(entry)

      explicit, glob = entry.include_sources
      assert explicit.explicit?
      refute explicit.glob?
      assert glob.glob?
      refute glob.explicit?
    end
  end

  def test_one_result_keeps_both_sources_when_two_includes_match
    with_files("a.rb" => "", "b.rb" => "") do
      snap = Rake::FileList["a.rb", "a.rb", "*.rb"].snapshot
      entry = snap["a.rb"]
      # Duplicate explicit arguments collapse to one source, glob adds one.
      assert_equal [:explicit, :glob], source_kinds(entry)
      assert_equal 1, snap.count { |e| e.path == "a.rb" }
    end
  end

  def test_exclude_records_the_deciding_rule
    with_files("a.rb" => "", "b.rb" => "") do
      snap = Rake::FileList["a.rb", "b.rb", "*.rb"].exclude("b.rb").snapshot

      assert_equal ["a.rb"], snap.paths
      assert_equal ["b.rb"], snap.excluded_paths

      entry = snap["b.rb"]
      assert entry.excluded?
      refute entry.included?
      rule = entry.excluded_by
      assert_equal :exact, rule.kind
      assert_equal "b.rb", rule.rule
      # Both include arguments explain where b.rb came from before the
      # exclude rule removed it.
      assert_equal [:explicit, :glob], source_kinds(entry)
    end
  end

  def test_regexp_and_block_excludes_report_their_kind
    with_files("a.rb" => "", "b.rb" => "", "c.rb" => "") do
      list = Rake::FileList["*.rb"].
             exclude(/^b\./) { |fn| fn == "c.rb" }
      snap = list.snapshot

      assert_equal :regexp, snap["b.rb"].excluded_by.kind
      assert_equal(/^b\./, snap["b.rb"].excluded_by.rule)

      c_rule = snap["c.rb"].excluded_by
      assert c_rule.block?
      assert_kind_of Proc, c_rule.rule
      assert_equal ["a.rb"], snap.paths
    end
  end

  def test_glob_exclude_rule_is_distinguished_from_exact_string
    with_files("a.rb" => "", "b.rb" => "") do
      snap = Rake::FileList["*.rb"].exclude("*.rb").snapshot
      assert_equal :glob, snap["a.rb"].excluded_by.kind
      assert_equal "*.rb", snap["a.rb"].excluded_by.rule
    end
  end

  def test_first_matching_exclude_in_order_decides
    with_files("a.rb" => "") do
      snap = Rake::FileList["a.rb"].
             clear_exclude.exclude(/a/, "a.rb").snapshot
      rule = snap["a.rb"].excluded_by
      assert_equal :regexp, rule.kind
      assert_equal 0, rule.order
    end
  end

  def test_snapshot_does_not_resolve_the_lazy_file_list
    with_files("a.rb" => "", "b.rb" => "") do
      list = Rake::FileList["*.rb"].exclude("b.rb")
      list.snapshot
      assert list.instance_variable_get(:@pending)
      assert_equal [], list.instance_variable_get(:@items)
    end
  end

  def test_snapshot_is_stable_when_files_are_added_afterwards
    with_files("a.rb" => "", "b.rb" => "") do
      list = Rake::FileList["*.rb"].exclude("b.rb")
      snap = list.snapshot

      File.write("c.rb", "")

      assert_equal ["a.rb"], snap.paths
      assert_nil snap["c.rb"]
      # The lazy list, in contrast, sees the new file when resolved.
      assert_includes list.to_a, "c.rb"
    end
  end

  def test_snapshot_is_stable_when_excludes_change_afterwards
    with_files("a.rb" => "", "b.rb" => "") do
      list = Rake::FileList["*.rb"]
      snap = list.snapshot
      list.exclude("a.rb")

      assert_equal ["a.rb", "b.rb"], snap.paths
      assert snap["a.rb"].included?
      assert_equal ["b.rb"], list.to_a
    end
  end

  def test_snapshot_arrays_are_independent_of_the_original
    with_files("a.rb" => "", "b.rb" => "") do
      list = Rake::FileList["a.rb", "*.rb"]
      snap = list.snapshot

      first  = snap.entries
      second = snap.entries
      refute first.equal?(second)

      paths = snap.paths
      paths << "mutated"
      assert_equal ["a.rb", "b.rb"], snap.paths

      list.resolve << "later.rb"
      assert_equal ["a.rb", "b.rb"], snap.paths
      assert snap["a.rb"].path.frozen?
    end
  end

  def test_path_order_is_stable
    with_files("z.rb" => "", "a.rb" => "", "m.rb" => "") do
      snap = Rake::FileList["*.rb"].snapshot
      assert_equal ["a.rb", "m.rb", "z.rb"], snap.map(&:path)
    end
  end

  def test_snapshot_of_an_already_resolved_list
    with_files("a.rb" => "", "b.rb" => "") do
      list = Rake::FileList["*.rb"].exclude("b.rb")
      list.resolve
      snap = list.snapshot

      assert_equal ["a.rb"], snap.paths
      assert_equal [:materialized], source_kinds(snap["a.rb"])
    end
  end

  def test_default_ignore_rules_are_reported_too
    with_files("a.bak" => "", "a.rb" => "") do
      snap = Rake::FileList["*"].snapshot
      rule = snap["a.bak"].excluded_by
      assert_equal :regexp, rule.kind
      assert_equal(["a.rb"], snap.paths)
    end
  end
end
