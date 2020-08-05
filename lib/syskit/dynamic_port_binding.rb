# frozen_string_literal: true

module Syskit
    # Resolve and re-resolve ports in the system
    #
    # It is rarely used as-is, the {Models::Component.data_reader} and
    # {Models::Component.data_writer} methods are much more ready-to-use.
    #
    # Dynamic port bindings allow to specify ports (or fields of these ports)
    # of interest. They then implement the machinery necessary to dynamically
    # resolve these ports and to provide a read interface from them.
    #
    # The goal is to provide a service-oriented view of the data sources in the
    # plan, for instance for the purpose of a UI or monitoring. Using dynamic
    # port resolvers, one may tag specific compositions or components with
    # services that are then used to 'find' the appropriate source at any given
    # state, in a way that's orthogonal from the data flow.
    #
    # @example find a running instance of a hypothetical ReferenceLocalization
    #   service and resolve its pose_samples port. The corresponding reader is
    #   available at runtime through the reference_pose_reader accessor
    #
    #   data_reader Services::ReferenceLocalization.pose_samples_port,
    #               as: 'reference_pose'
    class DynamicPortBinding
        # The resolver's model
        #
        # @return [Models::DynamicPortBinding]
        attr_reader :model

        def initialize(model)
            @model = model
            @port_resolver = nil
            @resolved_port = nil
            @accessor = nil
        end

        # The port's type
        #
        # @return [Class<Typelib::Type>]
        def type
            @model.type
        end

        # Whether this binds to an output or input port
        def output?
            @model.output?
        end

        # Returns whether {#attach_to_task} has been called
        def attached?
            @port_resolver
        end

        # Returns whether a port matching this resolver has been found
        def valid?
            @resolved_port
        end

        # Creates the accessor ({OutputReader} or {InputWriter}) matching
        # this binding's direction
        def to_data_accessor(**policy)
            if output?
                OutputReader.new(self, **policy)
            else
                InputWriter.new(self, **policy)
            end
        end

        # Creates the bound accessor ({BoundOutputReader} or {BoundInputWriter}) matching
        # this binding's direction
        def to_bound_data_accessor(name, component, **policy)
            if output?
                BoundOutputReader.new(name, component, self, **policy)
            else
                BoundInputWriter.new(name, component, self, **policy)
            end
        end

        # Gives a reference task to the port binding
        #
        # When created, port bindings (and therefore accessors) are unbound.
        # That is, they do not know (yet) the plan and task they should use
        # as reference to resolve the port (and accessor)
        #
        # This call "attaches" this accessor using the given task. This is
        # usually done once the task is in its final plan (i.e. just before
        # being executed)
        #
        # @see Accessor#attach_to_task
        def attach_to_task(task)
            @port_resolver = @model.instanciate_port_resolver(task)
            self
        end

        # Update the resolved port
        #
        # @return [(Boolean,(Port,nil))] tuple whose first element is true if
        #   the port was updated, and false otherwise. The tuple's second element
        #   is the new resolved port which may be nil if no ports can be found
        def update
            port = @port_resolver&.update
            return false, @resolved_port if @resolved_port == port

            @resolved_port = port
            [true, port]
        end

        # Resets the currently resolved port
        #
        # Note that calling {#update} after calling {#reset} might re-resolve
        # the same port (in which case {#update} will return true)
        def reset
            @resolved_port = nil
        end

        # @api private
        #
        # Generic implementation of read/write accessors on top of a {DynamicPortBinding}
        class Accessor
            # The currently found accessor
            #
            # @return [OutputReader,InputWriter]
            attr_reader :port_binding

            # The connection policy
            #
            # @return [Hash]
            attr_reader :policy

            # The currently found accessor
            #
            # @return [OutputReader,InputWriter]
            attr_reader :resolved_accessor

            def initialize(port_binding, **policy)
                @port_binding = port_binding
                @policy = policy
                @resolved_accessor = nil
            end

            # (see DynamicPortBinding#attach_to_task)
            def attach_to_task(task)
                @port_binding.attach_to_task(task)
                self
            end

            # Returns whether an accessor (reader or writer) has been resolved
            def valid?
                @resolved_accessor
            end

            # Returns whether an accessor is found and is connected to the port
            def connected?
                @resolved_accessor&.connected?
            end

            # Update the underlying data accessor if needed
            #
            # @return [Boolean] true if this accessor is valid, that is if it is
            #   backed by an underlying port
            #
            # @see valid? connected?
            def update
                updated, port = @port_binding.update
                return port unless updated

                @resolved_accessor&.disconnect
                @resolved_accessor = port && create_accessor(port)
                true
            end

            # Disconnect the current accessor, and reset the port binding
            #
            # Calling {#update} afterwards will re-connect to the same port
            # if the port binding resolves to the same port
            #
            # @see DynamicPortBinding#reset
            def disconnect
                @resolved_accessor&.disconnect
                @resolved_accessor = nil
                @port_binding.reset
            end
        end

        # Data reader tied to a {DynamicPortBinding}
        class OutputReader < Accessor
            def initialize(
                port_binding,
                value_resolver: Models::DynamicPortBinding::IdentityValueResolver.new,
                **policy
            )
                super(port_binding, **policy)
                @value_resolver = value_resolver
            end

            # @api private
            #
            # Method called by {Accessor} to create the accessor object from a
            # port
            def create_accessor(port)
                port.reader(**policy)
            end

            # Read data, either already read or new
            #
            # @param [Typelib::Type] sample an optional typelib value of the port's
            #    type, to fill with data. Passing it allows to avoid allocation.
            # @return [nil,Typelib::Type] nil if there is has never been any data, or if
            #    there are no underlying port. A data sample otherwise.
            def read(sample = nil)
                return unless (sample = @resolved_accessor&.read(sample))

                @value_resolver.__resolve(sample)
            end

            # Read new data
            #
            # @param [Typelib::Type] sample an optional typelib value of the port's
            #    type, to fill with data. Passing it allows to avoid allocation.
            # @return [nil,Typelib::Type] nil if there is no new data or if there are
            #    no underlying port. A data sample otherwise.
            def read_new(sample = nil)
                return unless (sample = @resolved_accessor&.read_new(sample))

                @value_resolver.__resolve(sample)
            end
        end

        # Generic implementation of {BoundOutputReader} and {BoundInputWriter}
        module BoundAccessor
            # The name under which this reader is registered on {#component}
            attr_reader :name
            # The component this reader is bound to
            attr_reader :component

            def initialize(name, component, *arguments, **kw_arguments)
                @name = name
                @component = component

                super(*arguments, **kw_arguments)
            end

            def attach
                attach_to_task(@component)
            end
        end

        # A {OutputReader} instance that is part of the implementation of a component
        class BoundOutputReader < OutputReader
            include BoundAccessor

            def to_s
                "#{component}.#{name}_reader"
            end
        end

        # Data writer tied to a {DynamicPortBinding}
        class InputWriter < Accessor
            def create_accessor(port)
                port.writer(**policy)
            end

            # Return a value that can be used to write in {#write}
            def new_sample
                @port_binding.type.zero
            end

            # Read data, either already read or new
            #
            # @return [nil,Typelib::Type] nil if there is has never been any data, or if
            #    there are no underlying port. A data sample otherwise.
            def write(sample)
                @resolved_accessor&.write(sample)
            end
        end

        # An {InputWriter} instance that is part of the implementation of a component
        class BoundInputWriter < InputWriter
            include BoundAccessor

            def to_s
                "#{component}.#{name}_writer"
            end
        end

        # @api private
        #
        # Resolver object to find a port within a plan using a {Queries::PortMatcher}
        class MatcherPortResolver
            def initialize(plan, matcher)
                @plan = plan
                @matcher = matcher
                @last_provider_task = nil
            end

            def update
                port = @matcher.each_in_plan(@plan).first
                port&.to_actual_port
            end

            def self.instanciate(task, model)
                new(task.plan, model.port_model)
            end
        end

        # @api private
        #
        # Resolver object that returns a port from a composition
        class ComponentPortResolver
            def initialize(port)
                @port = port
            end

            def update
                @port if @port.component.plan
            end

            def self.instanciate(task, model)
                new(model.port_model.bind(task))
            end
        end

        # @api private
        #
        # Resolver object that resolves a port from a composition child,
        # and returns it until the underlying task is finalized
        class CompositionChildPortResolver
            def initialize(port)
                @port = port
            end

            def update
                @port if @port.component.to_task.plan
            end

            def self.instanciate(task, model)
                child = model.port_model.component_model
                             .resolve_and_bind_child_recursive(task)
                new(model.port_model.bind(child))
            end
        end
    end
end
