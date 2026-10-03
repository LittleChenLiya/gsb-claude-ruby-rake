# frozen_string_literal: true
module Rake
  ##
  # A Parameter declares a single typed task argument: its name, the
  # converter used to turn the raw string value into a typed value,
  # whether it is required, and a default value (or a default factory).
  #
  # Parameters are declared on a task via the +parameter+ DSL method and
  # are bound (converted) before the task's action executes.  The raw
  # string argument interface is unchanged: tasks without a parameter
  # schema still receive plain strings.
  #
  #   parameter :build, :count, Integer
  #   parameter :build, :mode, String, required: false, default: "debug"
  #   parameter :build, :retries, default: 3
  #   parameter :build, :label { |v| v.strip }
  #
  class Parameter
    # The parameter name (a Symbol).
    attr_reader :name

    # The converter callable used to bind the raw value.
    attr_reader :converter

    # The default value or default factory (nil if none).
    attr_reader :default

    # Create a parameter declaration.
    #
    # +converter+ may be any callable, or one of the bare conversion
    # classes Integer, Float, String, ... (wrapped via the corresponding
    # Kernel conversion method).  If a block is given it is used as the
    # converter.  When neither is given the value is passed through
    # unchanged.
    #
    #   Parameter.new(:count, Integer)
    #   Parameter.new(:mode, String, required: false, default: "debug")
    #   Parameter.new(:retries, default: 3)
    #   Parameter.new(:label) { |v| v.strip }
    #
    def initialize(name, converter = nil, required: true, default: nil, &block)
      @name = name.to_sym
      @converter = Rake.converter_for(converter || block || IDENTITY)
      @required = required
      @default = default
    end

    # Returns true if the parameter is required (the default).
    def required?
      @required
    end

    # Returns true if the parameter has a default value or factory.
    def has_default?
      !@default.nil?
    end

    # Convert the raw value using the parameter's converter.
    def convert(value)
      @converter.call(value)
    end

    # Return the default value.  If the default is a factory (a callable),
    # it is called once and the result is returned.
    def default_value
      @default.respond_to?(:call) ? @default.call : @default
    end

    # The identity converter: returns the value unchanged.
    IDENTITY = ->(value) { value }
  end

  ##
  # Raised when a required parameter is missing and has no default.
  #
  class ParameterMissing < StandardError
    # The full path of the task (e.g. "namespace:task").
    attr_reader :task_path

    # The name of the missing parameter.
    attr_reader :param_name

    def initialize(task_path, param_name)
      @task_path = task_path
      @param_name = param_name
      super("missing required parameter '#{param_name}' " \
            "for task '#{task_path}'")
    end
  end

  ##
  # Raised when a parameter value cannot be converted to its declared type.
  #
  class ParameterBindingError < StandardError
    # The full path of the task (e.g. "namespace:task").
    attr_reader :task_path

    # The name of the parameter that failed to convert.
    attr_reader :param_name

    # The raw value that failed to convert.
    attr_reader :raw_value

    # The original exception raised by the converter.
    attr_reader :original

    def initialize(task_path, param_name, raw_value, original)
      @task_path = task_path
      @param_name = param_name
      @raw_value = raw_value
      @original = original
      super("cannot convert parameter '#{param_name}' of task '#{task_path}' " \
            "(raw value: #{raw_value.inspect}): #{original.message}")
    end
  end

  ##
  # Built-in converters.  Each is a callable that turns a raw string into
  # a typed value.  The same converter objects are reused across tasks so
  # that compatible declarations can share already-bound values without
  # converting again.
  #
  module Converters
    INTEGER = ->(value) { Integer(value) }
    FLOAT   = ->(value) { Float(value) }
    STRING  = ->(value) { String(value) }
    SYMBOL  = ->(value) { value.to_sym }
    BOOLEAN = ->(value) do
      case value
      when true, "true", "yes", "on", "1", 1 then true
      when false, "false", "no", "off", "0", 0 then false
      else
        raise ArgumentError, "invalid value for Boolean(): #{value.inspect}"
      end
    end
  end

  # Wrap a converter argument.  Callables are returned as-is.  Bare
  # conversion classes (Integer, Float, String, ...) are wrapped in a
  # cached lambda that calls the corresponding Kernel conversion method,
  # so the same class always yields the same converter object.
  def self.converter_for(converter)
    return converter if converter.respond_to?(:call)
    if converter.is_a?(Class) && Kernel.respond_to?(converter.name)
      WRAPPED_CONVERTERS[converter] ||=
        ->(value) { Kernel.public_send(converter.name, value) }
    else
      raise ArgumentError, "converter must be callable: #{converter.inspect}"
    end
  end

  WRAPPED_CONVERTERS = {} # :nodoc:
end
