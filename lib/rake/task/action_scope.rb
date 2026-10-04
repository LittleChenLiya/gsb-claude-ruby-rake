# frozen_string_literal: true
module Rake
  class Task
    # An ActionScope temporarily replaces a Task's actions within a block.
    # When the block exits (whether normally or because of an exception),
    # the task's original actions and its previous invoke state are restored.
    #
    # ActionScopes are scoped to a single Rake::Application and may be
    # nested; nested scopes are restored in LIFO order.
    #
    # This is intended for one-off verification: replace a task's action,
    # run the verification, and then restore the task exactly as it was.
    #
    #   task :foo do
    #     puts "original"
    #   end
    #
    #   Rake::Task.with_action(:foo) do |scope|
    #     scope.action { puts "temporary" }
    #     Rake::Task[:foo].invoke   # runs the temporary action
    #   end
    #
    #   Rake::Task[:foo].invoke     # runs the original action again
    #
    class ActionScope
      # The task whose actions are being replaced.
      attr_reader :task

      def initialize(task) # :nodoc:
        @task = task
        @active = false
        @saved_actions = nil
        @recorded = {}
      end

      # Begin the scope. Records the task's current invoke state, reenables
      # the task so the temporary action can run, and saves its current
      # actions. Returns self.
      def enter
        raise "action scope already active" if @active
        @active = true
        @recorded[@task] = [@task.already_invoked, @task.invocation_exception]
        @task.reenable
        @saved_actions = @task.actions.dup
        self
      end

      # End the scope. Restores the task's original actions and the invoke
      # state of every task recorded while the scope was active. Safe to
      # call multiple times; only the first call has any effect.
      def exit
        return unless @active
        @task.actions.replace(@saved_actions) if @saved_actions
        @recorded.each do |task, (already_invoked, invocation_exception)|
          task.restore_invoke_state(already_invoked, invocation_exception)
        end
        @active = false
      end

      # Replace the task's actions with the given block.
      def action(&block)
        raise ArgumentError, "block required" unless block_given?
        @task.actions.clear
        @task.actions << block
        self
      end

      # Record the current invoke state of +task+ if it has not been recorded
      # already. Used by the task invocation hook so that tasks invoked during
      # the scope can have their previous state restored.
      def record_invocation(task) # :nodoc:
        return if @recorded.key?(task)
        @recorded[task] = [task.already_invoked, task.invocation_exception]
      end
    end
  end
end
