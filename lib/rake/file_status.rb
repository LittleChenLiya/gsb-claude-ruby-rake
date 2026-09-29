# frozen_string_literal: true
module Rake

  # FileStatus is the default source of file system state used while
  # resolving and evaluating tasks.  It answers the two questions asked by
  # the time based dependency rules: does a file exist (#exist?), and what
  # is its modification time (#mtime).
  #
  # Alternative implementations can be injected (see Rake::TaskPreview) to
  # evaluate a task graph against a hypothetical file system without
  # touching (or modifying) the real one.
  class FileStatus
    # Return +true+ if the file named +file_name+ exists.
    def exist?(file_name)
      File.exist?(file_name)
    end

    # Return the modification time of +file_name+.  Raise
    # Errno::ENOENT when the file does not exist.
    def mtime(file_name)
      File.mtime(file_name)
    end
  end
end
