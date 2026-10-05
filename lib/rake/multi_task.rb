# frozen_string_literal: true
module Rake

  # Same as a regular task, but the immediate prerequisites are done in
  # parallel using Ruby threads.
  #
  # == Cancellation
  #
  # A multitask invocation can be cancelled by calling #cancel. Once
  # cancelled:
  #
  # * Prerequisites that have not yet started (still queued) will not run.
  # * Prerequisites that are already running are allowed to finish
  #   cooperatively.
  # * The parent action will not start.
  #
  # #cancel blocks until all in-flight work has completed, so it is safe
  # to release any resources a blocked prerequisite is waiting on and then
  # join the invoking thread.
  #
  # The cancellation state is scoped to a single invocation; reusing a
  # pooled thread for the next call does not carry the cancelled state.
  # Tasks that already completed successfully keep their normal cache (see
  # Task#already_invoked); use the existing reenable protocol to run them
  # again.
  #
  #   multitask build: [:compile, :package] do
  #     # ...
  #   end
  #
  #   thread = Thread.new { Rake::Task[:build].invoke }
  #   # wait for :compile to start, then:
  #   Rake::Task[:build].cancel
  #   thread.join
  #
  class MultiTask < Task
    def initialize(task_name, app)
      super
      @cancel_token = nil
      @cancel_monitor = Monitor.new
    end

    # Request cancellation of this multitask invocation.
    #
    # Queued prerequisites will be skipped, running prerequisites will be
    # allowed to finish, and the parent action will not run. Blocks until
    # all in-flight work has completed. Returns nil.
    def cancel
      token = @cancel_monitor.synchronize { @cancel_token }
      token&.cancel
      nil
    end

    def execute(args=nil) # :nodoc:
      return if @cancel_token&.cancelled?
      super
    end

    # Public so that Task#invoke_prerequisites can call it on a
    # MultiTask prerequisite (the superclass method is protected, but a
    # protected override cannot be called from the superclass).
    def invoke_with_call_chain(task_args, invocation_chain) # :nodoc:
      token = CancellationToken.new
      @cancel_monitor.synchronize { @cancel_token = token }
      super
    ensure
      @cancel_monitor.synchronize { @cancel_token = nil }
    end

    private

    def invoke_prerequisites(task_args, invocation_chain) # :nodoc:
      invoke_prerequisites_concurrently(task_args, invocation_chain)
    end

    def invoke_prerequisites_concurrently(task_args, invocation_chain) # :nodoc:
      token = @cancel_token
      futures = prerequisite_tasks.map do |p|
        prereq_args = task_args.new_scope(p.arg_names)
        application.thread_pool.future(p) do |r|
          token.enter
          begin
            if token.cancelled?
              # Not yet started: skip this prerequisite.
            else
              r.invoke_with_call_chain(prereq_args, invocation_chain)
            end
          ensure
            token.leave
          end
        end
      end
      # With a single-threaded pool the invoking thread must run the work
      # itself, so use #value. With threads, use #wait so the invoking
      # thread does not steal queued work (which must be skipped when
      # cancelled).
      if application.thread_pool.max_threads > 0
        futures.reverse_each(&:wait)
      else
        futures.reverse_each(&:value)
      end
    end
  end

  # Tracks cancellation state for a single multitask invocation.
  #
  # The token is created per invocation so that reusing a pooled thread
  # for a subsequent call does not carry the cancelled state.
  class CancellationToken # :nodoc:
    def initialize
      @cancelled = false
      @in_flight = 0
      @mon = Monitor.new
      @cond = @mon.new_cond
    end

    # Mark the token as cancelled and wait for all in-flight work to finish.
    def cancel
      @mon.synchronize do
        @cancelled = true
        @cond.wait_while { @in_flight > 0 }
      end
    end

    # Has the token been cancelled?
    def cancelled?
      @mon.synchronize { @cancelled }
    end

    # Record that a future has started running.
    def enter
      @mon.synchronize { @in_flight += 1 }
    end

    # Record that a future has finished running.
    def leave
      @mon.synchronize do
        @in_flight -= 1
        @cond.broadcast if @in_flight == 0
      end
    end
  end
end
