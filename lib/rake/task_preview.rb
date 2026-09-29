# frozen_string_literal: true
module Rake

  # A TaskPreview performs a read only dry run of a task graph.
  #
  # Given a target task and an injectable source of file system state,
  # TaskPreview walks the existing prerequisite graph using the same time
  # based +needed?+ rules as a regular invocation and reports which tasks
  # would run and why a file task is considered out of date.  It never
  # executes an action, never writes a file, and never invokes a user
  # defined +needed?+ method.
  #
  # The file status provider must respond to:
  #
  #   exist?(file_name) # => true or false
  #   mtime(file_name)  # => Time, raising Errno::ENOENT when missing
  #
  # State is queried at most once per path during a single preview, so the
  # resulting report always reflects one fixed snapshot, even if the
  # underlying provider changes while the preview runs.
  class TaskPreview

    # An Entry records the preview decision for a single task.
    class Entry
      # The evaluated Rake::Task.
      attr_reader :task

      # Symbol describing why the task is needed.  One of:
      #
      # +:missing+:: the file represented by the task does not exist
      # +:stale+:: the file is older than one of its prerequisites
      # +:always+:: a non file task is always considered needed
      attr_reader :reason

      # Ordered list of prerequisite task names that made a +:stale+ file
      # task out of date.  Empty for the other reasons.
      attr_reader :causes

      def initialize(task, reason, causes = []) # :nodoc:
        @task = task
        @reason = reason
        @causes = causes
      end

      # Name of the task.
      def name
        task.name
      end

      # True when the file represented by the task does not exist.
      def missing?
        reason == :missing
      end

      # True when the file is older than one of its prerequisites.
      def stale?
        reason == :stale
      end

      # True when the task is a regular, non file task.
      def always_needed?
        reason == :always
      end

      # True when the task would be executed by a real invocation.
      def needed?
        !reason.nil?
      end

      def to_s # :nodoc:
        case reason
        when :missing
          "#{name} (missing)"
        when :stale
          if causes.empty?
            "#{name} (stale)"
          else
            "#{name} (stale due to #{causes.join(", ")})"
          end
        when :always
          "#{name} (task)"
        else
          name
        end
      end
    end

    # The ordered result of a preview.  +entries+ lists every visited task
    # in the same prerequisites first order in which a real invocation
    # would execute it.  +needed+ lists only the entries that would run.
    class Report
      attr_reader :entries

      def initialize(entries) # :nodoc:
        @entries = entries
      end

      # Entries for tasks that would actually be executed.
      def needed
        entries.select(&:needed?)
      end

      # Names of the tasks that would actually be executed.
      def needed_names
        needed.map(&:name)
      end

      def each(&block) # :nodoc:
        entries.each(&block)
      end

      include Enumerable

      def to_s # :nodoc:
        entries.select(&:needed?).map(&:to_s).join("\n")
      end
    end

    # A FileStatus wrapper that memoizes every answer so that one preview
    # always observes a single, fixed snapshot of the file state.
    class Snapshot
      def initialize(file_status) # :nodoc:
        @file_status = file_status
        @exist = {}
        @mtime = {}
      end

      def exist?(file_name) # :nodoc:
        return @exist[file_name] if @exist.key?(file_name)
        @exist[file_name] = @file_status.exist?(file_name)
      end

      def mtime(file_name) # :nodoc:
        return @mtime[file_name] if @mtime.key?(file_name)
        @mtime[file_name] = begin
          @file_status.mtime(file_name)
        rescue Errno::ENOENT
          nil
        end
        @mtime[file_name] || (raise Errno::ENOENT, file_name)
      end
    end

    # Build a preview for +target+ (a task name or Rake::Task).  When no
    # +file_status+ is given the real file system is used.
    def initialize(target, file_status = nil)
      @target = target
      @file_status = file_status
    end

    # Convenience entry point.  See #run.
    def self.preview(target, file_status = nil)
      new(target, file_status).run
    end

    # Walk the prerequisite graph and return a Report.  No actions are
    # executed and no files are written.
    def run
      target = @target
      application = target.is_a?(Task) ? target.application : Rake.application
      snapshot = Snapshot.new(@file_status || application_default_status(application))
      now = Time.now

      entries = []
      seen = {}
      with_status(application, snapshot) do
        root = target.is_a?(Task) ? target : application[target]
        visit(root, InvocationChain::EMPTY, entries, seen, snapshot, now)
      end
      Report.new(entries)
    end

    private

    def application_default_status(application)
      application.respond_to?(:file_status) ?
        application.file_status : FileStatus.new
    end

    def with_status(application, snapshot)
      if application.respond_to?(:file_status=)
        previous = application.file_status
        application.file_status = snapshot
        begin
          yield
        ensure
          application.file_status = previous
        end
      else
        yield
      end
    end

    def visit(task, chain, entries, seen, snapshot, now)
      new_chain = InvocationChain.append(task, chain)
      if seen.key?(task.name)
        # Already visited via another prerequisite; like a real invocation
        # each task is evaluated once and its subtree is not revisited.
        return
      end
      seen[task.name] = true

      prerequisite_tasks = task.prerequisite_tasks
      prerequisite_tasks.each do |prerequisite|
        visit(prerequisite, new_chain, entries, seen, snapshot, now)
      end
      entries << evaluate(task, snapshot, now)
    end

    def evaluate(task, snapshot, now)
      reason = nil
      causes = []

      if task.instance_of?(FileTask)
        if snapshot.exist?(task.name)
          causes = stale_causes(task, snapshot, now)
          reason = :stale unless causes.empty?
        else
          reason = :missing
        end
      elsif task.is_a?(FileTask)
        # Built in file creation style tasks (for example FileCreationTask)
        # use fixed timestamps and are needed only while the file is
        # missing.  User defined FileTask subclasses are not invoked here;
        # their custom needed? rules cannot run during a preview.
        if task.is_a?(FileCreationTask)
          reason = :missing unless snapshot.exist?(task.name)
        else
          reason = :always
        end
      else
        reason = :always
      end

      Entry.new(task, reason, causes)
    end

    # Mirror Rake::FileTask#out_of_date? using the existing prerequisite
    # graph and time rules, but read all timestamps from the snapshot.
    def stale_causes(task, snapshot, now)
      stamp = timestamp_of(task, snapshot, now)
      build_all = task.application.options.build_all
      all_prerequisites = task.all_prerequisite_tasks
      all_prerequisites.select { |prerequisite|
        prereq_stamp = timestamp_of(prerequisite, snapshot, now)
        if prerequisite.instance_of?(FileTask)
          prereq_stamp > stamp || build_all
        else
          prereq_stamp > stamp
        end
      }.map(&:name)
    end

    def timestamp_of(task, snapshot, now)
      if task.instance_of?(FileTask)
        begin
          snapshot.mtime(task.name)
        rescue Errno::ENOENT
          LATE
        end
      elsif task.is_a?(FileCreationTask)
        EARLY
      else
        now
      end
    end
  end
end
