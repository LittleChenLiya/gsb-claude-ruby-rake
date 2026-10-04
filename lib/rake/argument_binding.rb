# frozen_string_literal: true
module Rake

  ##
  # Raised when a declared argument binding cannot be satisfied: a
  # required argument is missing, or a converter rejects the raw text.
  # The message always carries the full task path (including any
  # namespace) and the offending argument name.
  #
  class ArgumentBindingError < StandardError
    # Full name (task path) of the task whose binding failed.
    attr_reader :task_name

    # Name of the argument that failed to bind.
    attr_reader :argument_name

    def initialize(task_name, argument_name, reason)
      @task_name = task_name
      @argument_name = argument_name
      super("Argument #{argument_name.inspect} of task #{task_name.inspect}: #{reason}")
    end
  end

  ##
  # ArgumentBinding is an explicit, opt-in type-binding layer for task
  # arguments.  It does not change the classic string-based argument
  # interface: tasks that never declare a binding behave exactly as
  # before, and the raw values in TaskArguments are never mutated.
  #
  # A binding declares, for each named argument:
  #
  # * a converter (+as:+ a registered symbol such as :integer, or
  #   +convert:+ any callable, or a block),
  # * whether the argument is +required+,
  # * an optional +default+ (a plain value, or a factory callable that
  #   is invoked at most once per task invocation).
  #
  # All conversions are completed before any action runs.  If any
  # conversion fails, the actions of the task are not executed and no
  # partially bound values are left behind in TaskArguments.
  #
  # Explicit empty strings and missing values are kept distinct: an
  # explicit "" is handed to the converter as-is and is never silently
  # swapped for the default; defaults only fill genuinely missing
  # arguments.
  #
  # When a parent task has already bound a value and passes it down to
  # a prerequisite that declares a compatible converter, the bound
  # value is reused without re-conversion.  If the child declares a
  # different converter, the original raw text is re-validated against
  # the declaration of the child, and failures are reported with the
  # child task path.
  #
  # Example:
  #
  #   task :deploy, [:count, :tag]
  #   Rake::Task[:deploy].bind_argument :count, as: :integer, required: true
  #   Rake::Task[:deploy].bind_argument :tag, default: -> { "untagged" }
  #
  class ArgumentBinding

    ##
    # Describes the binding of a single argument.
    class Spec
      #  Argument name (a Symbol).
      attr_reader :name

      # The converter callable (or nil for pass-through).
      attr_reader :converter

      def initialize(name, converter, required, default) # :nodoc:
        @name = name.to_sym
        @converter = converter
        @required = required
        @default = default
      end

      # Is this argument required (no default allowed to fill it)?
      def required?
        @required
      end

      # Does this argument declare a default?
      def default?
        !@default.nil?
      end

      # Compute the default value.  A callable default is treated as a
      # factory and called; any other object is used as-is.
      def default_value
        @default.respond_to?(:call) ? @default.call : @default
      end

      # Run the converter over the raw (string) value.
      def convert(raw)
        @converter ? @converter.call(raw) : raw
      end

      # A converter is compatible iff it is the very same object, so
      # built-in converters referenced by name and shared lambdas are
      # recognized as identical declarations.
      def compatible_converter?(other_converter)
        @converter.equal?(other_converter)
      end
    end

    # Registry of named, reusable converters.  Because each entry is a
    # single shared object, declarations that reference the same name
    # are considered compatible and bound values are not re-converted.
    CONVERTERS = {
      string:  ->(s) { s },
      symbol:  ->(s) { s.to_sym },
      integer: ->(s) { Integer(s) },
      float:   ->(s) { Float(s) },
      boolean: ->(s) {
        case s
        when "true", "yes", "on", "1"  then true
        when "false", "no", "off", "0" then false
        else raise ArgumentError, "invalid boolean: #{s.inspect}"
        end
      },
    }

    # Resolve a converter given as a registered name (Symbol found in
    # CONVERTERS) or return the callable as-is.
    def self.resolve_converter(as)
      return nil if as.nil?
      return CONVERTERS[as] if as.is_a?(Symbol) && CONVERTERS.key?(as)
      return as if as.respond_to?(:call)
      raise ArgumentError, "unknown converter: #{as.inspect}"
    end

    def initialize # :nodoc:
      @specs = []
    end

    # Declare the binding of one argument.  Returns self so
    # declarations can be chained.
    def add(name, as: nil, convert: nil, required: false, default: nil, &block)
      converter = block || convert || self.class.resolve_converter(as)
      @specs.reject! { |spec| spec.name == name.to_sym }
      @specs << Spec.new(name, converter, required, default)
      self
    end

    # True when no argument has been declared.
    def empty?
      @specs.empty?
    end

    # Declared argument names, in declaration order.
    def names
      @specs.map(&:name)
    end

    ##
    # Complete every declared conversion against +args+ and return a
    # new TaskArguments carrying the bound values.  Neither +args+ nor
    # any parent argument object is modified.  Raises
    # ArgumentBindingError (naming +task_name+ as the task path) on the
    # first failure; in that case no TaskArguments is produced and the
    # original arguments of the caller are left untouched, so no
    # half-bound state can leak.
    def bind(task_name, args)
      return args if empty?

      entries = {}
      @specs.each do |spec|
        entry = bind_one(task_name, args, spec)
        entries[spec.name] = entry if entry
      end
      args.apply_binding(entries)
    end

    private

    def bind_one(task_name, args, spec)
      name = spec.name
      entry = args.bound_entry(name)

      if entry
        # The parent layer already bound this argument.
        if spec.compatible_converter?(entry.converter)
          # Compatible declaration: reuse the bound value as-is.
          return entry
        end
        # Different declaration: re-validate the original raw text.
        return convert_raw(task_name, spec, entry.raw)
      end

      raw, missing = raw_value_of(args, name)

      if missing
        if spec.default?
          # Defaults only fill missing arguments.  The factory is
          # invoked here, at most once per task invocation.
          return TaskArguments::BoundArgument.new(spec.converter, nil, spec.default_value)
        end
        if spec.required?
          raise ArgumentBindingError.new(task_name, name, "required argument is missing")
        end
        return nil
      end

      # An explicit empty string reaches the converter as "" and is
      # never silently replaced by the default.
      convert_raw(task_name, spec, raw)
    end

    def convert_raw(task_name, spec, raw)
      TaskArguments::BoundArgument.new(spec.converter, raw, spec.convert(raw))
    rescue ArgumentBindingError
      raise
    rescue Exception => ex
      raise ArgumentBindingError.new(
        task_name, spec.name,
        "cannot convert #{raw.inspect} (#{ex.class}: #{ex.message})")
    end

    # Distinguish "missing" (no value supplied at all) from an
    # explicitly supplied empty string, using the raw positional
    # values rather than the filtered hash.
    def raw_value_of(args, name)
      index = args.names.index(name.to_sym)
      if index
        values = args.to_a
        return [nil, true] if index >= values.length || values[index].nil?
        return [values[index], false]
      end
      value = args[name]
      value.nil? ? [nil, true] : [value, false]
    end
  end
end
