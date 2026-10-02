# frozen_string_literal: true

module Rake
  class FileList

    # A Snapshot is an eagerly resolved, immutable record of a FileList at a
    # single point in time. Unlike the lazy FileList, whose contents are only
    # globbed and filtered the first time they are accessed (and which can
    # change as files are added or exclude rules adjusted afterwards), a
    # snapshot:
    #
    # * resolves every pending +include+ pattern against the file system at
    #   once,
    # * remembers, for each path, every +include+ rule that matched it
    #   (distinguishing explicit file names from glob patterns), and
    # * remembers which +exclude+ rule (regexp, glob, exact string or block)
    #   finally decided that the path should be removed.
    #
    # Taking a snapshot never resolves or otherwise mutates the original
    # FileList; its lazy object is left untouched. The snapshot's arrays are
    # independent copies, so later changes to the file system or to the
    # FileList never affect an already generated snapshot.
    #
    # Example:
    #
    #   file_list = FileList["a.rb", "*.rb"].exclude("b.rb")
    #   snap      = file_list.snapshot
    #
    #   snap.paths                # => ["a.rb"]  (b.rb was excluded)
    #   snap["a.rb"].included?    # => true
    #   snap["a.rb"].include_sources
    #   # => [#<struct Rake::FileList::Snapshot::IncludeSource
    #   #      kind=:explicit, pattern="a.rb">,
    #   #     #<struct ... kind=:glob, pattern="*.rb">]
    #   snap["b.rb"].excluded?    # => true
    #   snap["b.rb"].excluded_by  # => #<struct ... rule="b.rb">
    #
    class Snapshot

      # One resolved path recorded by a Snapshot.
      #
      # +include_sources+ is the ordered list of {IncludeSource} records of
      # every include rule that produced the path. +excluded_by+ is +nil+ for
      # a path that survived filtering, otherwise the {ExcludeRule} that
      # removed it.
      Entry = Struct.new(:path, :include_sources, :excluded_by) do
        # Was this path kept by the file list (i.e. not excluded)?
        def included?
          excluded_by.nil?
        end

        # Was this path removed by an exclude rule?
        def excluded?
          !included?
        end
      end

      # Records that an include rule (an explicit file name or a glob
      # pattern) matched a path. +kind+ is +:explicit+ for a literal file
      # name, +:glob+ for a pattern containing glob metacharacters, or
      # +:materialized+ for a path already present in a resolved file list;
      # +pattern+ is the rule itself (or the path for materialized entries).
      IncludeSource = Struct.new(:kind, :pattern) do
        # True when the source was an explicit file name argument.
        def explicit?
          kind == :explicit
        end

        # True when the source was a glob pattern argument.
        def glob?
          kind == :glob
        end

        # True when the path was already materialized in the file list and
        # has no recorded include argument.
        def materialized?
          kind == :materialized
        end

        def to_s # :nodoc:
          "#{kind}:#{pattern.inspect}"
        end
      end

      # Records the exclude rule that removed a path. +order+ is the rule's
      # zero-based position among rules of its own kind (patterns are checked
      # first, then blocks, matching the order in which FileList evaluates
      # them), +kind+ is one of +:regexp+, +:glob+, +:exact+ or +:block+, and
      # +rule+ is the rule itself (a Regexp, a glob String, an exact-match
      # String or a Proc).
      ExcludeRule = Struct.new(:order, :kind, :rule) do
        def to_s # :nodoc:
          label = block? ? "block" : rule.inspect
          "exclude##{order} #{kind} #{label}"
        end

        # True when the deciding rule was a block given to FileList#exclude.
        def block?
          kind == :block
        end
      end

      # Build a snapshot from +file_list+ without resolving or mutating it.
      # Use FileList#snapshot instead of calling this directly.
      def initialize(file_list)
        @entries, @by_path = build(file_list)
      end

      # All recorded entries in stable, first-seen path order, including
      # paths that were later excluded. Returns a fresh array.
      def entries
        @entries.dup
      end
      alias to_a entries

      # Iterate over every recorded entry (including excluded ones).
      def each(&block)
        return enum_for(__method__) unless block_given?
        @entries.each(&block)
        self
      end

      include Enumerable

      # The entry recorded for +path+, or +nil+ if the path never matched any
      # include rule.
      def [](path)
        @by_path[path]
      end

      # Paths kept by the file list (excludes applied), in stable order.
      def paths
        select_paths(included: true)
      end

      # Paths removed by an exclude rule, in stable order.
      def excluded_paths
        select_paths(included: false)
      end

      # Entries kept by the file list (excludes applied).
      def included_entries
        @entries.select(&:included?)
      end

      # Entries removed by an exclude rule.
      def excluded_entries
        @entries.select(&:excluded?)
      end

      # Number of recorded entries (kept and excluded together).
      def size
        @entries.size
      end
      alias length size

      def inspect # :nodoc:
        "#<#{self.class} #{paths.inspect}>"
      end

      private

      # Reproduce FileList's resolution order and exclusion semantics while
      # recording the include and exclude provenance of every path. The
      # original file list is never touched.
      def build(file_list)
        patterns = file_list.instance_variable_get(:@exclude_patterns)
        procs    = file_list.instance_variable_get(:@exclude_procs)
        pattern_table = rule_table(patterns) { |pat| rule_kind(pat) }
        block_table   = rule_table(procs) { :block }

        collected = {}

        # Paths already materialized in the file list come first, exactly as
        # they do when FileList#resolve runs.
        file_list.instance_variable_get(:@items).each do |fn|
          path = Rake.from_pathname(fn).to_s
          remember(collected, path,
                   IncludeSource.new(:materialized, path.dup.freeze))
        end

        # Then the pending include arguments, in their original order.
        file_list.instance_variable_get(:@pending_add).each do |fn|
          fn = Rake.from_pathname(fn)
          source_kind = fn =~ GLOB_PATTERN ? :glob : :explicit
          source = IncludeSource.new(source_kind, fn.to_s.dup.freeze)
          matched =
            if source_kind == :glob
              Dir.glob(fn).sort
            else
              [fn]
            end
          matched.each do |path|
            remember(collected, Rake.from_pathname(path).to_s, source)
          end
        end

        entries = collected.map do |path, sources|
          rule = matching_rule(pattern_table, patterns, path) ||
                 matching_rule(block_table, procs, path)
          Entry.new(path.dup.freeze, sources.dup.freeze, rule)
        end
        by_path = {}
        entries.each { |entry| by_path[entry.path] = entry }
        [entries, by_path]
      end

      def remember(collected, path, source)
        entry = (collected[path] ||= [])
        entry << source unless entry.include?(source)
      end

      def rule_table(rules)
        table = {}
        rules.each_with_index do |rule, index|
          table[rule.object_id] = ExcludeRule.new(index, yield(rule), rule)
        end
        table
      end

      def rule_kind(pat)
        case pat
        when Regexp then :regexp
        when GLOB_PATTERN then :glob
        else :exact
        end
      end

      def matching_rule(table, rules, path)
        rules.each do |rule|
          record = table[rule.object_id]
          return record if rule_matches?(record.kind, rule, path)
        end
        nil
      end

      # Mirror FileList#excluded_from_list?
      def rule_matches?(kind, rule, path)
        case kind
        when :regexp
          path =~ rule
        when :glob
          flags = File::FNM_PATHNAME
          flags |= File::FNM_EXTGLOB if defined?(File::FNM_EXTGLOB)
          File.fnmatch?(rule, path, flags)
        when :exact
          path == rule
        when :block
          rule.call(path)
        end
      end

      def select_paths(included:)
        @entries.select { |entry| entry.included? == included }.map(&:path)
      end
    end
  end
end
