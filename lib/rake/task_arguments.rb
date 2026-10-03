# frozen_string_literal: true
module Rake

  ##
  # TaskArguments manage the arguments passed to a task.
  #
  # TaskArguments carry the raw string values supplied on the command
  # line (the original string parameter interface).  When a task declares
  # a parameter schema (see Rake::Parameter), the raw values are bound
  # (converted) before the task action executes.  The binding layer
  # tracks, per argument, the original raw text and the converter that
  # produced the typed value, so that:
  #
  # * explicit empty strings are kept distinct from missing values and
  #   are passed to the converter rather than replaced by a default;
  # * already-bound values inherited from a parent argument object are
  #   reused without conversion when the parent converter is compatible
  #   with the declared converter;
  # * when the child converter differs, the original raw text is
  #   re-checked with the new converter;
  # * a failed conversion never leaves half-bound values behind.
  #
  class TaskArguments
    include Enumerable

    # Argument names
    attr_reader :names

    # Create a TaskArgument object with a list of argument +names+ and a set
    # of associated +values+.  +parent+ is the parent argument object.
    #
    # +raw_values+ may be supplied when +values+ already holds typed
    # (bound) values inherited from a parent; otherwise the raw values
    # default to +values+.  +bound+ is an internal hash of bound state
    # produced by #bind.
    def initialize(names, values, parent=nil, raw_values: nil, bound: nil)
      @names = names
      @parent = parent
      @values = values
      @hash = {}
      @raw = {}
      @bound = bound || {}
      raw_values ||= values
      names.each_with_index { |name, i|
        v = values[i]
        r = raw_values[i]
        @raw[name.to_sym] = r unless r.nil?
        @hash[name.to_sym] = v unless v.nil? || v == ""
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
      raw_values = names.map { |n| raw_value(n) }
      self.class.new(names, values + extras, self,
                     raw_values: raw_values + extras)
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
      if @bound.empty?
        @hash.each(&block)
      else
        @names.each do |name|
          v = lookup(name)
          block.call(name, v) unless v.nil?
        end
      end
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
      if @bound.empty?
        @hash.dup
      else
        result = {}
        @names.each do |name|
          v = lookup(name)
          result[name] = v unless v.nil? || v == ""
        end
        result
      end
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
      @bound.has_key?(key) || @hash.has_key?(key) ||
        (@parent && @parent.has_key?(key))
    end
    alias key? has_key?

    def fetch(*args, &block)
      key = args.first
      if key && has_key?(key)
        lookup(key)
      else
        @hash.fetch(*args, &block)
      end
    end

    def deconstruct_keys(keys)
      keys ? @hash.slice(*keys) : to_hash
    end

    ##
    # Bind the raw string values of this argument object to typed values
    # according to +schema+ (a Hash of name => Rake::Parameter).  Binding
    # is atomic: every parameter is converted before the bound argument
    # object is returned, so a failed conversion never leaves half-bound
    # values behind.
    #
    # Already-bound values inherited from a parent argument object are
    # reused without conversion when the parent converter is compatible
    # with (the same object as) the declared converter.  Otherwise the
    # original raw text is re-checked with the new converter.  An explicit
    # empty string is passed to the converter and is never replaced by a
    # default; defaults only fill missing values.
    #
    # Returns a new TaskArguments with the bound values; the receiver (and
    # any parent argument object) is not modified.
    #
    def bind(schema, task_path)
      names = schema.keys.map(&:to_sym)
      bound = {}
      raw = {}
      names.each do |name|
        param = schema[name]
        raw_val = raw_value(name)
        if raw_val.nil?
          if param.has_default?
            bound[name] = { value: param.default_value, raw: nil,
                             converter: nil }
          elsif param.required?
            raise ParameterMissing.new(task_path, name)
          else
            bound[name] = { value: nil, raw: nil, converter: nil }
          end
        elsif raw_val == ""
          bound[name] = { value: convert(param, raw_val, task_path, name),
                          raw: raw_val, converter: param.converter }
        elsif bound?(name) && same_converter?(bound_by(name), param.converter)
          bound[name] = { value: lookup(name), raw: raw_val,
                          converter: bound_by(name) }
        else
          bound[name] = { value: convert(param, raw_val.to_s, task_path, name),
                          raw: raw_val, converter: param.converter }
        end
        raw[name] = raw_val
      end
      values = names.map { |n| bound[n][:value] }
      self.class.new(names, values, nil,
                     raw_values: names.map { |n| raw[n] }, bound: bound)
    end

    # Returns the original raw string value for +name+, walking the parent
    # chain.  Returns nil when the argument was not provided.  An explicit
    # empty string is returned as "" (it is not confused with a missing
    # value).
    def raw_value(name)
      name = name.to_sym
      if @bound.has_key?(name)
        @bound[name][:raw]
      elsif @raw.has_key?(name)
        @raw[name]
      elsif @parent
        @parent.raw_value(name)
      end
    end

    # Returns true if the value for +name+ has already been bound (typed).
    def bound?(name)
      name = name.to_sym
      @bound.has_key?(name) || (@parent && @parent.bound?(name))
    end

    # Returns the converter that bound the value for +name+ (nil if not
    # bound).  Walks the parent chain.
    def bound_by(name)
      name = name.to_sym
      if @bound.has_key?(name)
        @bound[name][:converter]
      elsif @parent
        @parent.bound_by(name)
      end
    end

    protected

    def lookup(name) # :nodoc:
      if @bound.has_key?(name)
        @bound[name][:value]
      elsif @hash.has_key?(name)
        @hash[name]
      elsif @parent
        @parent.lookup(name)
      end
    end

    private

    def convert(param, raw, task_path, name)
      param.convert(raw)
    rescue => ex
      raise ParameterBindingError.new(task_path, name, raw, ex)
    end

    def same_converter?(a, b)
      a.equal?(b) || a == b
    end
  end

  EMPTY_TASK_ARGS = TaskArguments.new([], []) # :nodoc:
end
