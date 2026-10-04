# frozen_string_literal: true
module Rake

  ##
  # TaskArguments manage the arguments passed to a task.
  #
  class TaskArguments
    include Enumerable

    ##
    # A BoundArgument records the result of converting one argument
    # through the Rake::ArgumentBinding layer: the +converter+ that
    # produced the value, the original +raw+ text, and the bound
    # +value+ itself.  Keeping the raw text allows a child task with a
    # different declaration to re-validate the original input.
    class BoundArgument
      attr_reader :converter, :raw, :value

      def initialize(converter, raw, value)
        @converter = converter
        @raw = raw
        @value = value
      end
    end

    # Argument names
    attr_reader :names

    # Create a TaskArgument object with a list of argument +names+ and a set
    # of associated +values+.  +parent+ is the parent argument object.
    def initialize(names, values, parent=nil)
      @names = names
      @parent = parent
      @hash = {}
      @values = values
      @bound = {}
      names.each_with_index { |name, i|
        next if values[i].nil? || values[i] == ""
        @hash[name.to_sym] = values[i]
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
    # names.  Bound entries produced by the argument binding layer are
    # carried over by name so a prerequisite with a compatible
    # declaration can reuse the already converted value.
    def new_scope(names)
      values = names.map { |n| self[n] }
      result = self.class.new(names, values + extras, self)
      names.each do |n|
        entry = bound_entry(n)
        result.send(:store_bound_entry, n.to_sym, entry) if entry
      end
      result
    end

    # Return the BoundArgument recorded for +name+, searching the
    # parent argument chain when needed.  Returns nil when the
    # argument was never converted by the binding layer.
    def bound_entry(name)
      key = name.to_sym
      if @bound.has_key?(key)
        @bound[key]
      elsif @parent
        @parent.bound_entry(key)
      end
    end

    # Return true when +name+ carries a bound (already converted)
    # value.
    def bound?(name)
      !bound_entry(name).nil?
    end

    ##
    # Return a new TaskArguments in which every entry of +entries+ (a
    # hash of name => BoundArgument) is applied.  The receiver and its
    # parents are never modified, so a binding that fails partway
    # leaves no half-bound values behind.
    def apply_binding(entries)
      copy = dup
      copy.instance_variable_set(:@hash, @hash.dup)
      copy.instance_variable_set(:@bound, @bound.dup)
      entries.each do |name, entry|
        copy.send(:store_bound_entry, name.to_sym, entry)
      end
      copy
    end

    # Find an argument value by name or index.
    def [](index)
      lookup(index.to_sym)
    end

    # Specify a hash of default values for task arguments. Use the
    # defaults only if there is no specific value for the given
    # argument.
    def with_defaults(defaults)
      @hash = defaults.merge(@hash)
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

    def store_bound_entry(name, entry) # :nodoc:
      @bound[name] = entry
      @hash[name] = entry.value
    end

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
