# frozen_string_literal: true
require_relative "file_task"
require "digest"
require "json"

module Rake

  ####################################################################
  # A FingerprintFileTask is a FileTask whose rebuild decision is based on
  # explicit content fingerprints (SHA-256 digests) of its declared input
  # files and its output file, together with a caller supplied
  # +task_version+, instead of relying on file modification times.
  #
  # A task of this kind is rebuilt when any of the following holds:
  #
  # * its output file is missing,
  # * there is no (valid) fingerprint record for it,
  # * the caller supplied +task_version+ has changed,
  # * the SHA-256 digest of the output file changed since the record was
  #   written,
  # * the SHA-256 digest of any declared input file changed since the
  #   record was written.
  #
  # Conversely, touching an input or output file (changing only its mtime)
  # does *not* trigger a rebuild, and editing an input file triggers a
  # rebuild even if its mtime is restored to the previous value.
  #
  # After the actions of the task complete successfully, the fingerprints
  # are written to a record file (atomically, via a temporary file plus
  # rename).  If an action fails, no record is written.  If the content of
  # an input file changes *while* the actions run, the result is not
  # trusted: no completion is recorded and the task is rebuilt on the next
  # run.
  #
  # == Supported dependency scope
  #
  # Only explicitly declared prerequisites that resolve to local regular
  # files (Rake::FileTask) are fingerprinted.  Any prerequisite that is not
  # a Rake::FileTask (a plain task, a multitask, a directory task, ...)
  # cannot be fingerprinted; the documented enforcement policy for such
  # prerequisites is conservative: their presence forces the task to be
  # considered out of date on every run.
  #
  # == Fingerprint record recovery rules
  #
  # * A missing record file simply forces one rebuild, after which the
  #   record is rewritten.
  # * A corrupt or unreadable record (truncated JSON, unknown format) is
  #   treated like a missing record: the task is rebuilt and the record is
  #   rewritten on success.
  # * Leftover temporary files (<tt>*.tmp-PID</tt>) from an interrupted
  #   write are ignored and may be deleted; they never count as a valid
  #   completion.
  # * Deleting the record (or the whole fingerprint directory) is always
  #   safe and only costs one rebuild.
  #
  # This class is not loaded by default; require it explicitly:
  #
  #   require "rake/fingerprint_file_task"
  #
  # and declare tasks with the +fingerprint_file+ DSL method:
  #
  #   fingerprint_file({ "report.txt" => ["data.csv"] }, version: 3) do |t|
  #     File.write(t.name, transform(File.read(t.source)))
  #   end
  #
  # The plain Rake::FileTask keeps its classic timestamp semantics and is
  # not affected by this class.
  #
  class FingerprintFileTask < FileTask

    # Default directory (relative to the current working directory) where
    # fingerprint records are stored.
    DEFAULT_FINGERPRINT_DIR = ".rake_fingerprints"

    # Record format version written to and expected from record files.
    RECORD_FORMAT = 1

    # Caller supplied version of this task.  Changing the version forces a
    # rebuild on the next run.  Any object; compared by its +to_s+ form.
    attr_accessor :task_version

    # Directory where the fingerprint record of this task is stored.
    # Defaults to DEFAULT_FINGERPRINT_DIR.
    attr_accessor :fingerprint_dir

    def initialize(task_name, app)
      super
      @task_version = nil
      @fingerprint_dir = DEFAULT_FINGERPRINT_DIR
    end

    # Is this task needed?  Yes if the output is missing, the fingerprint
    # record is missing or invalid, the task version changed, any
    # fingerprint (input or output) changed, or a non-file prerequisite
    # forces a rebuild.
    def needed?
      return true if application.options.build_all
      return true unless File.file?(name)
      return true unless non_file_prerequisites.empty?
      record = read_record
      return true if record.nil?
      return true unless record["version"] == task_version.to_s
      inputs = current_input_fingerprints
      return true if inputs.nil? || inputs != record["inputs"]
      outputs = current_output_fingerprints
      return true if outputs.nil? || outputs != record["outputs"]
      false
    end

    # Execute the actions and, only on success, atomically record the
    # fingerprints.  If an input file changed while the actions ran, no
    # completion is recorded so the next run rebuilds the task.
    def execute(args=nil)
      inputs_before = current_input_fingerprints
      super
      record_completion(inputs_before)
    end

    # Path of the fingerprint record file for this task.
    def record_path
      File.join(fingerprint_dir, self.class.record_file_name(name))
    end

    # Record file name for a (possibly namespaced or pathed) task name.
    def self.record_file_name(task_name)
      task_name.gsub(/[^A-Za-z0-9_.-]/, "_") + ".json"
    end

    private

    # Prerequisites that cannot be fingerprinted because they are not file
    # tasks.  Their presence forces a rebuild on every run (documented
    # conservative policy).
    def non_file_prerequisites
      prerequisite_tasks.reject { |t| t.is_a?(Rake::FileTask) }
    end

    # Hash of input file name => SHA-256 hex digest for every declared
    # file prerequisite.  Returns nil if any input is missing or is not a
    # regular local file (such inputs can never match a valid record).
    def current_input_fingerprints
      result = {}
      prerequisite_tasks.each do |t|
        next unless t.is_a?(Rake::FileTask)
        digest = digest_file(t.name)
        return nil if digest.nil?
        result[t.name] = digest
      end
      result
    end

    # Hash of output file name => SHA-256 hex digest, or nil if the output
    # is missing.
    def current_output_fingerprints
      digest = digest_file(name)
      digest.nil? ? nil : { name => digest }
    end

    def digest_file(path)
      return nil unless File.file?(path)
      Digest::SHA256.file(path).hexdigest
    end

    # Write the fingerprint record, but only if the inputs were stable
    # while the actions ran and the output now exists.
    def record_completion(inputs_before)
      return if application.options.dryrun
      inputs_after = current_input_fingerprints
      return if inputs_after.nil?
      if inputs_before != inputs_after
        if application.options.trace
          application.trace "** Fingerprint of #{name} not recorded " \
            "(inputs changed while the action was running)"
        end
        return
      end
      outputs = current_output_fingerprints
      return if outputs.nil?
      write_record(
        "format"  => RECORD_FORMAT,
        "task"    => name,
        "version" => task_version.to_s,
        "inputs"  => inputs_after,
        "outputs" => outputs
      )
    end

    # Read and validate the fingerprint record.  Returns nil when the
    # record is missing, unreadable, or corrupt (all treated the same:
    # the task is rebuilt and the record rewritten on success).
    def read_record
      return nil unless File.file?(record_path)
      record = JSON.parse(File.read(record_path))
      return nil unless record.is_a?(Hash)
      return nil unless record["format"] == RECORD_FORMAT
      return nil unless record["inputs"].is_a?(Hash)
      return nil unless record["outputs"].is_a?(Hash)
      record
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Atomically write the record: write a temporary file in the same
    # directory, then rename it over the record file.
    def write_record(record)
      FileUtils.mkdir_p(fingerprint_dir)
      tmp = "#{record_path}.tmp-#{Process.pid}"
      File.open(tmp, "w") { |f| f.write(JSON.generate(record)) }
      begin
        File.rename(tmp, record_path)
      rescue SystemCallError
        # Some platforms (e.g. Windows) cannot rename over an existing
        # file; remove the old record and retry the rename.
        FileUtils.rm_f(record_path)
        File.rename(tmp, record_path)
      end
    end
  end

  module DSL
    # Declare a FingerprintFileTask.  Takes the same arguments as the
    # +file+ DSL method, plus an optional +version:+ keyword that is
    # assigned to FingerprintFileTask#task_version.  Changing the version
    # forces a rebuild on the next run.
    def fingerprint_file(*args, version: nil, &block)
      task = Rake::FingerprintFileTask.define_task(*args, &block)
      task.task_version = version unless version.nil?
      task
    end
    private :fingerprint_file
  end
end
