# frozen_string_literal: true

module Syskit
    module Models
        # (see Syskit::DynamicPortBinding)
        class DynamicPortBinding
            # The underlying port model
            #
            # May either be a {Port} or a {PortMatcher}
            attr_reader :port_model

            # This resolver's data type
            attr_reader :type

            def initialize(port_model, type, output: port_model.output?, port_resolver:)
                @port_model = port_model
                @type = type
                @output = output
                @port_resolver = port_resolver
            end

            # Whether this binds to an output port or to an input port
            def output?
                @output
            end

            # Create the data accessor corresponding to the underlying's port direction
            #
            # @return [OutputReader,InputWriter]
            def to_data_accessor(**policy)
                if output?
                    OutputReader.new(self, **policy)
                else
                    InputWriter.new(self, **policy)
                end
            end

            # Create a bound data accessor corresponding to the underlying's
            # port direction
            #
            # @return [BoundOutputReader,BoundInputWriter]
            def to_bound_data_accessor(name, component_model, **policy)
                if output?
                    BoundOutputReader.new(name, component_model, self, **policy)
                else
                    BoundInputWriter.new(name, component_model, self, **policy)
                end
            end

            # Create a dynamic port binding from a port object or a port matcher
            #
            # A {Port} will return a binding based on a component port
            # ({#create_from_component_port}), a {Queries::PortMatcher}
            # will return a binding based on a query.
            def self.create(port)
                # Only PortMatcher responds to :match. Plain ports do not
                if port.respond_to?(:match)
                    create_from_matcher(port)
                else
                    create_from_component_port(port)
                end
            end

            # Create a {DynamicPortBinding} model from a component or
            # composition child port model
            def self.create_from_component_port(port)
                resolver =
                    if port.component_model.kind_of?(Models::CompositionChild)
                        Syskit::DynamicPortBinding::CompositionChildPortResolver
                    else
                        Syskit::DynamicPortBinding::ComponentPortResolver
                    end

                new(port, port.type, output: port.output?, port_resolver: resolver)
            end

            # Create a {DynamicPortBinding} model from a {Queries::PortMatcher}
            #
            # @param direction one of :auto, :input and :output. If :auto, the
            #   method will try to auto-detect the direction from the matcher
            #   and raise if it cannot be resolved (usually because the given
            #   port matcher resolves the port(s) by type and not by name)
            def self.create_from_matcher(matcher, direction: :auto)
                matcher = matcher.match

                unless %i[auto input output].include?(direction)
                    raise ArgumentError,
                          "'#{direction}' is not a valid value for the 'direction' "\
                          "option. Should be one of :auto, :input or :output"
                end

                if direction == :auto
                    unless (direction = matcher.try_resolve_direction)
                        raise ArgumentError,
                              "cannot create a dynamic data source from a matcher "\
                              "whose direction cannot be inferred"
                    end
                end

                unless (type = matcher.try_resolve_type)
                    raise ArgumentError,
                          "cannot create a dynamic data source from a matcher "\
                          "whose type cannot be inferred"
                end

                new(matcher, type,
                    output: direction == :output,
                    port_resolver: Syskit::DynamicPortBinding::MatcherPortResolver)
            end

            def instanciate
                Syskit::DynamicPortBinding.new(self)
            end

            # @api private
            #
            # Called at runtime to instanciate the port resolver using a task as anchor
            #
            # This instanciation must be delayed until the task is within its
            # execution plan (e.g. task startup)
            def instanciate_port_resolver(task)
                @port_resolver.instanciate(task, self)
            end

            # Model of a data reader bound to a {DynamicPortBinding}
            class OutputReader
                # The connection policy
                attr_reader :policy

                # The underlying port binding model
                #
                # @return [DynamicPortBinding]
                attr_reader :port_binding

                def initialize(port_binding, **policy)
                    @port_binding = port_binding
                    @policy = policy
                    @root_resolver = ValueResolver.new(self)
                end

                def type
                    @port_binding.type
                end

                # Specify that the read samples should be transformed with the given block
                #
                # This is a terminal action. No subfields and no other transforms may be
                # added further
                def transform(&block)
                    @root_resolver.transform(&block)
                end

                # Defined to match the {ValueResolver} interface
                def __reader
                    self
                end

                # Defined to match the {ValueResolver} interface
                def __resolve(value)
                    value
                end

                def respond_to_missing?(name, _)
                    @root_resolver.respond_to?(name)
                end

                def method_missing(name, *args, **keywords) # rubocop:disable Style/MethodMissingSuper
                    @root_resolver.__send__(name, *args, **keywords)
                end

                def instanciate(value_resolver: IdentityValueResolver.new)
                    port_binding = @port_binding.instanciate
                    Syskit::DynamicPortBinding::OutputReader.new(
                        port_binding, value_resolver: value_resolver, **policy
                    )
                end
            end

            # Common implementation of {BoundOutputReader} and {BoundInputWriter}
            module BoundAccessor
                # The name under which this reader is registered on {#component}
                attr_reader :name
                # The component this reader is bound to
                attr_reader :component_model

                def initialize(name, component_model, *arguments, **kw_arguments)
                    @name = name
                    @component_model = component_model

                    super(*arguments, **kw_arguments)
                end
            end

            # An {OutputReader} that is part of a {Component} implementation
            #
            # These are usually created through {Component.data_reader}
            class BoundOutputReader < OutputReader
                include BoundAccessor

                def instanciate(component, value_resolver: IdentityValueResolver.new)
                    port_binding = @port_binding.instanciate
                    Syskit::DynamicPortBinding::BoundOutputReader.new(
                        name, component, port_binding,
                        value_resolver: value_resolver, **policy
                    )
                end
            end

            # Model of a data writer bound to a {DynamicPortBinding}
            class InputWriter
                # The connection policy
                attr_reader :policy

                # The underlying port binding model
                #
                # @return [DynamicPortBinding]
                attr_reader :port_binding

                def initialize(port_binding, **policy)
                    @port_binding = port_binding
                    @policy = policy
                end

                def instanciate
                    Syskit::DynamicPortBinding::InputWriter.new(
                        @port_binding.instanciate, **policy
                    )
                end
            end

            # An {InputWriter} that is part of a {Component} implementation
            #
            # These are usually created through {Component.data_writer}
            class BoundInputWriter < InputWriter
                include BoundAccessor

                def instanciate(component)
                    Syskit::DynamicPortBinding::BoundInputWriter.new(
                        name, component, @port_binding.instanciate,
                        **policy
                    )
                end
            end

            # @api private
            #
            # Identity version of {ValueResolver}
            class IdentityValueResolver
                def __resolve(value)
                    value
                end
            end

            # @api private
            #
            # Object that resolves a field or sub-field out of a Typelib value
            class ValueResolver < BasicObject
                def initialize(reader, type: reader.type, path: [], transform: nil)
                    @reader = reader
                    @path = path
                    @type = type
                    @transform = transform
                end

                # The underlying reader
                #
                # @return [OutputReader]
                def __reader
                    @reader
                end

                def __resolve(value)
                    resolved_path = @path.inject(value) do |v, (m, args, _)|
                        v.send(m, *args)
                    end
                    resolved_path = ::Typelib.to_ruby(resolved_path)
                    if @transform
                        @transform.call(resolved_path)
                    else
                        resolved_path
                    end
                end

                def respond_to_missing?(name)
                    if @type <= ::Typelib::CompoundType
                        @type.has_field?(name)
                    elsif @type <= ::Typelib::ArrayType ||
                          @type <= ::Typelib::ContainerType
                        name == :[]
                    end
                end

                INSTANCE_METHODS = %I[__resolve __reader].freeze

                def respond_to?(name, _include_private = false)
                    INSTANCE_METHODS.include?(name) || respond_to_missing?(name)
                end

                def method_missing(name, *args, **keywords)
                    return super unless respond_to_missing?(name)

                    validate_common_method_missing_constraints(name, keywords)

                    if @type <= ::Typelib::ArrayType
                        __array_access(args)
                    elsif @type <= ::Typelib::ContainerType
                        __container_access(args)
                    elsif @type <= ::Typelib::CompoundType
                        __compound_access(name, args)
                    end
                end

                def validate_common_method_missing_constraints(name, keywords)
                    unless keywords.empty?
                        ::Kernel.raise(
                            ::ArgumentError,
                            "expected zero keyword arguments in `#{name}`"
                        )
                    end

                    if @transform
                        ::Kernel.raise(
                            ::ArgumentError,
                            "cannot refine a resolver on which .transform has been called"
                        )
                    end

                    nil
                end

                def __container_access(args)
                    __validate_indexed_access_arguments(args)
                    __indexed_access(args)
                end

                def __array_access(args)
                    __validate_indexed_access_arguments(args)

                    if @type.length <= args.first
                        ::Kernel.raise ::ArgumentError,
                                       "element #{args.first} out of bound in "\
                                       "an array of #{@type.length}"
                    end

                    __indexed_access(args)
                end

                def __validate_indexed_access_arguments(args)
                    if args.size != 1
                        ::Kernel.raise ::ArgumentError,
                                       "expected one argument, got #{args.size}"
                    elsif !args.first.kind_of?(::Numeric)
                        ::Kernel.raise ::TypeError,
                                       "expected an integer argument, got '#{args.first}'"
                    end
                end

                def __indexed_access(args)
                    new_step = [:raw_get, args, @type.deference]
                    ValueResolver.new(
                        @reader, path: @path.dup << new_step, type: new_step.last
                    )
                end

                def __compound_access(name, args)
                    unless args.empty?
                        ::Kernel.raise ::ArgumentError,
                                       "expected zero arguments to `#{name}`, "\
                                       "got #{args.size}"
                    end

                    new_step = [:raw_get, [name], @type[name]]
                    ValueResolver.new(
                        @reader, path: @path.dup << new_step, type: new_step.last
                    )
                end

                def transform(&block)
                    if @transform
                        ::Kernel.raise ::ArgumentError,
                                       "this resolver already has a transform block"
                    end
                    ValueResolver.new(
                        @reader, path: @path, type: @type, transform: block
                    )
                end

                def instanciate
                    @reader.instanciate(value_resolver: self)
                end
            end
        end
    end
end
