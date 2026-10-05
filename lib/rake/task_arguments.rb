# frozen_string_literal: true
module Rake

  ##
  # TaskArguments manage the arguments passed to a task.
  #
  class TaskArguments
    include Enumerable

    # Argument names
    attr_reader :names

    # Source kinds recorded for argument bindings.  The source of an
    # argument is tracked explicitly at the moment the binding is
    # created; it is never guessed from the final value.
    #
    # [+:argument+]  the value was explicitly supplied when the task
    #                was invoked.
    # [+:forwarded+] the value was forwarded from the argument scope of
    #                the task that invoked this one (via +new_scope+).
    # [+:default+]   the value came from +with_defaults+ because no
    #                explicit or forwarded value was present.
    SOURCE_ARGUMENT  = :argument
    SOURCE_FORWARDED = :forwarded
    SOURCE_DEFAULT   = :default

    # Create a TaskArgument object with a list of argument +names+ and a set
    # of associated +values+.  +parent+ is the parent argument object.
    def initialize(names, values, parent=nil)
      @names = names
      @parent = parent
      @hash = {}
      @values = values
      @sources = {}
      origin = parent ? SOURCE_FORWARDED : SOURCE_ARGUMENT
      names.each_with_index { |name, i|
        next if values[i].nil? || values[i] == ""
        @hash[name.to_sym] = values[i]
        @sources[name.to_sym] = origin
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
    # names.
    def new_scope(names)
      values = names.map { |n| self[n] }
      self.class.new(names, values + extras, self)
    end

    # Find an argument value by name or index.
    def [](index)
      lookup(index.to_sym)
    end

    # Specify a hash of default values for task arguments. Use the
    # defaults only if there is no specific value for the given
    # argument.
    #
    # A default is recorded as the source of an argument only when the
    # argument has no binding in this scope yet; existing bindings keep
    # their original source, and applying defaults again does not
    # re-record (or re-apply) sources that are already known.
    def with_defaults(defaults)
      defaults.each_key do |key|
        key = key.to_sym
        @sources[key] = SOURCE_DEFAULT unless @sources.has_key?(key)
      end
      @hash = defaults.merge(@hash)
    end

    # Returns the source of the given argument (+:argument+,
    # +:forwarded+ or +:default+), searching parent scopes when the
    # name is not bound in this scope.  Returns nil when the argument
    # is not bound anywhere in the scope chain.
    def source_of(name)
      name = name.to_sym
      if @sources.has_key?(name)
        @sources[name]
      elsif @parent
        @parent.source_of(name)
      end
    end

    # Returns the chain of sources recorded for +name+, starting with
    # this scope and walking outward through parent scopes.  Only
    # scopes that actually bind the name contribute to the chain.
    def source_chain(name)
      name = name.to_sym
      chain = []
      chain << @sources[name] if @sources.has_key?(name)
      chain.concat(@parent.source_chain(name)) if @parent
      chain
    end

    # Returns a map of argument names to their recorded sources for the
    # whole scope chain.  Argument values are never included.  When
    # several scopes bind the same name, the innermost scope wins
    # (mirroring value lookup).
    def source_trace
      trace = @parent ? @parent.source_trace : {}
      @sources.each { |key, source| trace[key] = source }
      trace
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

    def lookup(name) # :nodoc:
      if @hash.has_key?(name)
        @hash[name]
      elsif @parent
        @parent.lookup(name)
      end
    end
  end

  EMPTY_TASK_ARGS = TaskArguments.new([], []) # :nodoc:
end
