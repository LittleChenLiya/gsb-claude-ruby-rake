# frozen_string_literal: true
module Rake

  ##
  # TaskArguments manage the arguments passed to a task.
  #
  class TaskArguments
    include Enumerable

    # Argument names
    attr_reader :names

    # The task scope these arguments belong to.  Used as the scope for
    # default values applied to this task.
    attr_reader :scope

    # Whether the task owning these arguments actually bound (executed)
    # them.  Skipped (already invoked) tasks leave this false.
    attr_accessor :bound

    # Create a TaskArgument object with a list of argument +names+ and a set
    # of associated +values+.  +parent+ is the parent argument object.
    # +scope+ is the name of the task these arguments belong to.
    def initialize(names, values, parent=nil, scope=nil)
      @names = names
      @parent = parent
      @scope = scope
      @hash = {}
      @values = values
      @sources = {}
      @bound = false
      names.each_with_index { |name, i|
        next if values[i].nil? || values[i] == ""
        @hash[name.to_sym] = values[i]
        @sources[name.to_sym] = source_entry(:actual, scope)
      }
    end

    # Retrieve the complete array of sequential values
    def to_a
      @values.dup
    end

    # Retrieve the list of values not associated with named arguments
    def extras
      @values[@names.length..-1] || []
    end

    # Create a new argument scope using the prerequisite argument
    # names.  The +scope+ parameter names the prerequisite task so that
    # forwarded values can be distinguished from values bound in the
    # prerequisite itself.
    def new_scope(names, scope: nil)
      values = names.map { |n| self[n] }
      child_scope = scope || @scope
      child = self.class.new(names, values + extras, self, child_scope)
      names.each do |n|
        sym = n.to_sym
        if @sources[sym]
          child.sources[sym] = source_entry(:forwarded, @scope)
        end
      end
      child
    end

    # Find an argument value by name or index.
    def [](index)
      lookup(index.to_sym)
    end

    # Specify a hash of default values for task arguments. Use the
    # defaults only if there is no specific value for the given
    # argument.  Each default is recorded with the task's scope so the
    # source can be traced without inspecting the final value.
    def with_defaults(defaults)
      defaults.each do |key, value|
        sym = key.to_sym
        next unless arg_names.include?(sym)
        unless @hash.has_key?(sym)
          @hash[sym] = value
          @sources[sym] = source_entry(:default, @scope)
        end
      end
      self
    end

    # Enumerates the arguments and their values
    def each(&block)
      @hash.each(&block)
    end

    # Extracts the argument values at +keys+
    def values_at(*keys)
      keys.map { |k| lookup(k) }
    end

    # Returns the value of the given argument via method_missing
    def method_missing(sym, *args)
      lookup(sym.to_sym)
    end

    # Returns a Hash of arguments and their values
    def to_hash
      @hash.dup
    end

    # Returns a trace of argument sources.  Each entry maps an argument
    # name to a Hash containing the +kind+ (:actual, :default, or
    # :forwarded) and the +scope+ (task name) where the value was bound.
    # Values are never included in the trace.
    def trace
      @sources.transform_values { |entry| entry.dup }
    end

    def to_s # :nodoc:
      inspect
    end

    def inspect # :nodoc:
      inspection = @hash.map do |k,v|
        "#{k.to_s}: #{v.to_s}"
      end.join(", ")

      "#<#{self.class} #{inspection}>"
    end

    # Returns true if +key+ is one of the arguments
    def has_key?(key)
      @hash.has_key?(key)
    end
    alias key? has_key?

    def fetch(*args, &block)
      @hash.fetch(*args, &block)
    end

    def deconstruct_keys(keys)
      keys ? @hash.slice(*keys) : to_hash
    end

    protected

    def sources
      @sources
    end

    def lookup(name) # :nodoc:
      if @hash.has_key?(name)
        @hash[name]
      elsif @parent
        @parent.lookup(name)
      end
    end

    private

    def arg_names
      @arg_names ||= @names.map(&:to_sym)
    end

    def source_entry(kind, scope)
      { kind: kind, scope: scope }
    end
  end

  EMPTY_TASK_ARGS = TaskArguments.new([], []) # :nodoc:
end
