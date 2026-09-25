# frozen_string_literal: true
module Rake

  # Same as a regular task, but the immediate prerequisites are done in
  # parallel using Ruby threads.
  #
  class MultiTask < Task
    private

    def invoke_prerequisites(task_args, invocation_chain, session=nil) # :nodoc:
      invoke_prerequisites_concurrently(task_args, invocation_chain, session)
    end
  end
end
