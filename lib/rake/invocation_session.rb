# frozen_string_literal: true
module Rake

  # An InvocationSession captures the runtime state of a single "run" of a
  # task graph: which tasks have already been invoked, which invocations
  # failed, and the invocation chain used for circular dependency
  # detection.
  #
  # Sessions allow a long lived process to invoke the same task graph
  # multiple times without calling the global (task level) +reenable+.
  # Tasks invoked through a session do not mutate the task definition:
  # +already_invoked+, the stored invocation exception and the invocation
  # chain all live in the session, while the task's prerequisites and
  # action list remain shared, read-only definitions.
  #
  # Within one session, a shared prerequisite is executed exactly once,
  # even when reached through several branches of a diamond dependency or
  # through concurrent MultiTask branches.  Concurrent branches block on a
  # per-task session lock until the first execution finishes, and then
  # observe its result: a successful prerequisite is not re-run, and a
  # failed prerequisite re-raises the stored exception in every dependent
  # branch without re-running.
  #
  # Different sessions are fully independent: invoking a task in a new
  # session runs it again, and a failure recorded in one session never
  # leaks into another one.
  #
  # The traditional Rake::Task#invoke is unaffected and keeps its original
  # behavior (task level +already_invoked+ state plus +reenable+).
  #
  # Example:
  #
  #   session = Rake::InvocationSession.new
  #   session.invoke(:default)            # runs the graph once
  #   session.invoke(:default)            # no-op, already invoked
  #
  #   Rake::InvocationSession.new.invoke(:default)  # runs the graph again
  #
  class InvocationSession

    # Per-task runtime state owned by a session.  Each state carries its
    # own monitor so that concurrent MultiTask branches invoking the same
    # prerequisite in the same session wait for the first execution to
    # complete instead of merely observing that it has started.
    class TaskState # :nodoc:
      attr_accessor :already_invoked, :invocation_exception
      attr_reader :lock

      def initialize
        @already_invoked = false
        @invocation_exception = nil
        @lock = Monitor.new
      end
    end

    # The application whose tasks this session invokes.
    attr_reader :application

    # Create a session bound to +application+ (defaults to the current
    # Rake.application).
    def initialize(application = Rake.application)
      @application = application
      @states = {}
      @states_lock = Mutex.new
      @chain_stacks = {}
      @chain_stacks_lock = Mutex.new
    end

    # Invoke the task named +task_name+ with the given arguments inside
    # this session.  Returns immediately (without re-running) if the task
    # was already invoked successfully in this session, and re-raises the
    # recorded exception if the previous invocation failed.
    def invoke(task_name, *args)
      self[task_name].invoke_in_session(self, *args)
    end

    # Look up a task by name in the session's application.
    def [](task_name)
      application[task_name]
    end

    # Has +task+ already been invoked (successfully or not) in this
    # session?
    def already_invoked?(task)
      state_for(task).already_invoked
    end

    # The exception recorded for +task+ in this session, or nil.
    def invocation_exception(task)
      state_for(task).invocation_exception
    end

    # The invocation chain currently in effect on this thread.  Nested
    # invocations made from within task actions (via #invoke or
    # Rake::Task#invoke_in_session) continue this chain, so circular
    # dependencies are detected across recursive invocations.
    def current_chain
      stack = chain_stack
      stack.empty? ? InvocationChain::EMPTY : stack.last
    end

    # Run +block+ with +chain+ pushed as the current chain for this
    # thread.  Used internally while a task's prerequisites and actions
    # run inside the session.
    def with_chain(chain) # :nodoc:
      stack = chain_stack
      stack.push(chain)
      begin
        yield
      ensure
        stack.pop
      end
    end

    # Fetch the session state for +task+ and yield it while holding its
    # lock.  Used internally by Rake::Task.
    def with_task_state(task) # :nodoc:
      state = state_for(task)
      state.lock.synchronize { yield state }
    end

    private

    def state_for(task) # :nodoc:
      @states_lock.synchronize do
        @states[task.name] ||= TaskState.new
      end
    end

    def chain_stack # :nodoc:
      @chain_stacks_lock.synchronize do
        @chain_stacks[Thread.current] ||= []
      end
    end
  end
end
