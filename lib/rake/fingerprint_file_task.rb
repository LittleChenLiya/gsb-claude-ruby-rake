# frozen_string_literal: true
require_relative "file_task"
require "digest"
require "json"

module Rake

  # A FingerprintFileTask is a FileTask that decides whether to rebuild by
  # comparing content fingerprints (digests) of its explicit local regular
  # file prerequisites, the output file, and a caller-supplied task version.
  # It does *not* rely on mtime alone, so touching a file without changing its
  # content will not trigger a rebuild, while changing content but restoring
  # the original mtime will.
  #
  # == Fingerprint record
  #
  # After an action completes successfully, a fingerprint record is written
  # atomically (temp file + rename) next to the output file.  The record is a
  # JSON document containing:
  #
  #   {
  #     "version" => <caller version>,
  #     "inputs"  => { <prerequisite name> => <digest>, ... },
  #     "output"  => <digest of the output file>
  #   }
  #
  # The record is only written when the action succeeds and the input content
  # did not change while the action was running.  If the action raises, or if
  # the input content changed during the action, no valid record is kept and
  # the next run must rebuild.
  #
  # == Recovery rules
  #
  # The task is considered needed (will rebuild) when any of the following
  # holds:
  #
  # * the output file is missing;
  # * the fingerprint record is missing, unreadable, or corrupt;
  # * the recorded version differs from the current caller-supplied version;
  # * the digest of any explicit file prerequisite differs from the record;
  # * the digest of the output file differs from the record;
  # * a prerequisite is not an existing local regular file (non-file tasks,
  #   directories, missing files) -- these cannot be fingerprinted and follow
  #   the documented enforcement strategy of always forcing execution.
  #
  # Once a rebuild succeeds, a fresh record is written and subsequent runs
  # that match all fingerprints are skipped.
  #
  class FingerprintFileTask < FileTask

    # The caller-supplied task version.  Changing this forces a rebuild even
    # when every file content is unchanged.
    attr_accessor :version

    def initialize(task_name, app)
      super
      @version = nil
    end

    # Is this fingerprint file task needed?  Yes if the output is missing, the
    # fingerprint record is invalid, the version changed, or any file digest
    # changed.  Non-file prerequisites always force execution.
    def needed?
      return true if application.options.build_all
      return true unless File.file?(name)
      return true unless non_fingerprintable_prerequisites.empty?
      record = load_fingerprint_record
      return true unless record_valid?(record)
      false
    end

    # Execute the action, then atomically record the fingerprint.  The record
    # is only written when the action succeeds and the input content did not
    # change during the action.
    def execute(args = nil)
      if application.options.dryrun
        super
        return
      end
      before = snapshot_fingerprint_inputs
      super
      after = snapshot_fingerprint_inputs
      if before == after
        record_fingerprint(after)
      else
        invalidate_fingerprint
      end
    end

    # Path of the fingerprint record file, stored next to the output so the
    # atomic rename stays on the same filesystem.
    def fingerprint_record_path
      File.join(File.dirname(name), ".#{File.basename(name)}.fingerprint")
    end

    private

    # Validate a loaded fingerprint record against the current state.
    def record_valid?(record)
      return false unless record.is_a?(Hash)
      return false unless record["version"] == version.to_s
      return false unless record["inputs"] == snapshot_fingerprint_inputs
      return false unless record["output"] == digest_file(name)
      true
    end

    # Snapshot the digests of the explicit fingerprintable prerequisites.
    def snapshot_fingerprint_inputs
      result = {}
      fingerprintable_prerequisites.each do |pre|
        result[pre] = digest_file(pre)
      end
      result
    end

    # Explicit prerequisites that are existing local regular files.
    def fingerprintable_prerequisites
      prerequisites.select { |pre| File.file?(pre) }
    end

    # Prerequisites that cannot be fingerprinted (non-file tasks, directories,
    # missing files).  These force execution per the documented strategy.
    def non_fingerprintable_prerequisites
      prerequisites.reject { |pre| File.file?(pre) }
    end

    # Digest a single file.
    def digest_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    # Load the fingerprint record, returning nil when missing or corrupt.
    def load_fingerprint_record
      path = fingerprint_record_path
      return nil unless File.file?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Atomically write the fingerprint record.
    def record_fingerprint(inputs)
      record = {
        "version" => version.to_s,
        "inputs" => inputs,
        "output" => digest_file(name)
      }
      FileUtils.mkdir_p(File.dirname(fingerprint_record_path))
      atomic_write(fingerprint_record_path, JSON.pretty_generate(record))
    end

    # Remove the fingerprint record so the next run must rebuild.
    def invalidate_fingerprint
      path = fingerprint_record_path
      File.unlink(path) if File.exist?(path)
    rescue SystemCallError
      nil
    end

    # Write +content+ to +path+ atomically via a same-directory temp file and
    # a rename.  On Windows the destination is unlinked first because rename(2)
    # cannot replace an existing file there; the worst case is a missing
    # record (which forces a rebuild), never a partially written one.
    def atomic_write(path, content)
      temp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      begin
        File.open(temp, "wb") do |f|
          f.write(content)
          f.flush
          f.fsync
        end
        if Gem.win_platform?
          File.unlink(path) if File.exist?(path)
        end
        File.rename(temp, path)
      rescue
        File.unlink(temp) rescue nil
        raise
      end
    end

    # ----------------------------------------------------------------
    # Task class methods.
    #
    class << self
      # Extract the optional caller-supplied :version from the argument hash
      # before delegating to the standard task definition.
      def define_task(*args, &block)
        version = extract_version!(args)
        task = super(*args, &block)
        task.version = version
        task
      end

      private

      def extract_version!(args)
        return nil unless args.last.is_a?(Hash) && args.last.key?(:version)
        version = args.last.delete(:version)
        args.pop if args.last.empty?
        version
      end
    end
  end
end
