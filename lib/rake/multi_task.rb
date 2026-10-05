# frozen_string_literal: true
module Rake

  # Same as a regular task, but the immediate prerequisites are done in
  # parallel using Ruby threads.
  #
  # A multitask invocation can be canceled explicitly through
  # MultiTask#cancel. Cancellation does not interrupt work: prerequisites
  # that have already started are allowed to finish cooperatively, while
  # prerequisites that have not started yet are never executed and the
  # multitask's own actions do not run.
  class MultiTask < Task

    # Thread-local key holding the Cancellation of the multitask whose
    # prerequisite fan-out is currently running on this thread. The
    # value is set only for the duration of one invocation, so worker
    # threads never carry cancellation state when they are reused by a
    # later invocation.
    ACTIVE_CANCELLATION_KEY = :rake_multi_task_cancellation # :nodoc:

    # Token coordinating the explicit cancellation of one multitask
    # invocation.
    class Cancellation # :nodoc: all
      def initialize
        @monitor = Monitor.new
        @canceled = false
        @in_flight = 0
        @idle = @monitor.new_cond
      end

      # Returns false when the invocation has been canceled before this
      # attempt started. Otherwise registers the caller as an attempt in
      # flight and returns true; the caller must pair this with #finish.
      def begin_attempt
        @monitor.synchronize do
          return false if @canceled
          @in_flight += 1
          true
        end
      end

      # Marks a previously started attempt as finished.
      def finish
        @monitor.synchronize do
          @in_flight -= 1
          @idle.broadcast if @in_flight.zero?
        end
      end

      # Marks the invocation as canceled and blocks until every attempt
      # that had actually started has finished. Prerequisites merely
      # queued on the thread pool are not started and do not delay the
      # return.
      def cancel
        @monitor.synchronize do
          @canceled = true
          @idle.wait_while { @in_flight > 0 }
        end
        true
      end

      def canceled?
        @monitor.synchronize { @canceled }
      end
    end

    # The Cancellation active for the multitask fan-out running on the
    # current thread, or nil when there is none.
    def self.active_cancellation
      Thread.current[ACTIVE_CANCELLATION_KEY]
    end

    # Explicitly cancel the current invocation of this multitask.
    #
    # Prerequisites that have not started yet will not be executed,
    # while prerequisites already in progress are allowed to finish
    # cooperatively. The call returns only after all in-flight
    # prerequisites have actually completed, and this multitask's own
    # actions are then skipped. Cancellation is scoped to the current
    # invocation: it never lives on the pool worker threads, so reusing
    # the pool for a later invocation carries no canceled state; cached
    # results of prerequisites that completed successfully are left
    # untouched and, as usual, a later run requires the tasks to be
    # reenabled before anything executes again.
    #
    # Calling this when the multitask is not currently being invoked is a
    # no-op that returns false. Because #cancel waits for in-flight work,
    # it must not be called from inside one of this invocation's own
    # prerequisites; call it from another thread.
    def cancel
      token = @cancellation
      token ? token.cancel : false
    end

    # True when the current (or most recent) invocation of this multitask
    # was (or is being) canceled through #cancel. A prerequisite action
    # may consult it cooperatively to wind its own work down.
    def canceled?
      (@cancellation || @last_cancellation)&.canceled? == true
    end

    private

    def invoke_prerequisites(task_args, invocation_chain) # :nodoc:
      token = Cancellation.new
      @cancellation = token
      previous = Thread.current[ACTIVE_CANCELLATION_KEY]
      Thread.current[ACTIVE_CANCELLATION_KEY] = token
      begin
        invoke_prerequisites_concurrently(task_args, invocation_chain)
      ensure
        Thread.current[ACTIVE_CANCELLATION_KEY] = previous
        @cancellation = nil
        @last_cancellation = token
      end
    end

    # The parent actions never start once the invocation has been
    # canceled.
    def continue_after_prerequisites? # :nodoc:
      !@last_cancellation&.canceled?
    end
  end
end
