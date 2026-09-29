# frozen_string_literal: true
require_relative "task"
require_relative "file_task"
require_relative "file_creation_task"
require_relative "invocation_chain"

module Rake

  # A Rehearsal performs a read-only preview of a task invocation.
  #
  # Given a target task and an injectable file state provider, it walks the
  # existing prerequisite graph and applies the same timestamp rules that
  # FileTask uses to decide whether it is needed, but it never executes
  # actions, never writes files and never calls user defined +needed?+ or
  # +timestamp+ methods.
  #
  # The result is a Report listing, in stable build order, every task that
  # would run, and for each outdated FileTask exactly which prerequisite
  # files made it out of date.
  #
  # Example:
  #
  #   report = Rake::Rehearsal.new.plan("app.o")
  #   report.entries.each do |entry|
  #     puts entry
  #   end
  #
  class Rehearsal

    # Default file state provider backed by the real file system.  Any
    # object responding to +exist?(path)+ and +mtime(path)+ may be injected
    # instead.  +mtime+ may raise Errno::ENOENT or return nil for files that
    # do not exist.
    class FileStateProvider
      def exist?(path)
        File.exist?(path)
      end

      def mtime(path)
        File.mtime(path)
      end
    end

    # A single task that a rehearsal predicts would run.
    class Entry
      # The task that would run.
      attr_reader :task

      # The prerequisite tasks whose timestamps made this task out of date.
      # Empty for plain tasks and for missing files.
      attr_reader :causes

      def initialize(task, causes, missing) # :nodoc:
        @task = task
        @causes = causes
        @missing = missing
      end

      # Name of the task that would run.
      def name
        task.name
      end

      # True if the task is needed because its file does not exist.
      def missing?
        @missing
      end

      def to_s
        if missing?
          "#{name} (missing)"
        elsif !causes.empty?
          "#{name} (out of date: #{causes.map(&:name).join(', ')})"
        else
          name
        end
      end
    end

    # The outcome of a rehearsal: an ordered list of entries for every task
    # that would run, prerequisites before their dependents.
    class Report
      include Enumerable

      attr_reader :entries # :nodoc:

      def initialize(entries) # :nodoc:
        @entries = entries
      end

      def each(&block)
        entries.each(&block)
      end

      # True when nothing would run.
      def empty?
        entries.empty?
      end

      # The tasks that would run, in build order.
      def tasks
        entries.map(&:task)
      end

      # The names of the tasks that would run, in build order.
      def task_names
        entries.map(&:name)
      end

      def to_s
        entries.map(&:to_s).join("\n")
      end
    end

    # The application whose task graph is rehearsed.
    attr_reader :application

    # The file state provider consulted for existence and timestamps.
    attr_reader :file_state

    def initialize(application=Rake.application, file_state: nil)
      @application = application
      @file_state = file_state || FileStateProvider.new
    end

    # Rehearse invoking +task_name+ (a name or a Rake::Task) and return a
    # Report.  The file state is frozen for the duration of one plan, so a
    # single rehearsal always sees a consistent snapshot.
    def plan(task_name)
      task = Rake::Task === task_name ? task_name : application[task_name]
      @now = Time.now
      @mtime_cache = {}
      @exist_cache = {}
      entries = []
      visit(task, InvocationChain::EMPTY, {}, entries)
      Report.new(entries)
    end

    private

    def visit(task, chain, visited, entries)
      new_chain = InvocationChain.append(task, chain)
      return if visited[task.name]
      visited[task.name] = true
      task.prerequisite_tasks.each do |prerequisite|
        visit(prerequisite, new_chain, visited, entries)
      end
      entry = analyze(task)
      entries << entry if entry
    end

    # Decide, using only the built-in rules, whether the task would run.
    # User defined +needed?+ implementations are never called.
    def analyze(task)
      case task
      when Rake::FileCreationTask
        Entry.new(task, [], true) unless exist?(task.name)
      when Rake::FileTask
        file_task_entry(task)
      else
        Entry.new(task, [], false)
      end
    end

    def file_task_entry(task)
      return Entry.new(task, [], true) unless exist?(task.name)
      stamp = mtime(task.name)
      causes = task.all_prerequisite_tasks.select { |prerequisite|
        timestamp_of(prerequisite) > stamp
      }
      if causes.empty? && !application.options.build_all
        nil
      else
        Entry.new(task, causes, false)
      end
    end

    # Timestamp rules mirroring the built-in task classes, without calling
    # any user defined +timestamp+ method.
    def timestamp_of(task)
      case task
      when Rake::FileCreationTask
        Rake::EARLY
      when Rake::FileTask
        mtime(task.name) || Rake::LATE
      else
        @now
      end
    end

    def mtime(path)
      return @mtime_cache[path] if @mtime_cache.key?(path)
      @mtime_cache[path] =
        begin
          file_state.mtime(path)
        rescue Errno::ENOENT
          nil
        end
    end

    def exist?(path)
      return @exist_cache[path] if @exist_cache.key?(path)
      @exist_cache[path] = file_state.exist?(path) ? true : false
    end
  end
end
