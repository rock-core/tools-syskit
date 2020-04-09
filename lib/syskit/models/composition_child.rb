# frozen_string_literal: true

module Syskit
    module Models
        # Used by Composition to define its children. Values returned by
        # {Models::Composition#find_child} are instances of that class.
        class CompositionChild < InstanceRequirements
            # [Models::Composition] the model of the composition this child is
            # part of
            attr_reader :composition_model
            # [String] the name of this child on {#composition_model}
            attr_reader :child_name
            # The set of models that this child should fullfill. It is a
            # Set which contains at most one Component model and any number
            # of data service models
            attr_accessor :dependency_options
            # [InstanceSelection] information needed to update the composition's
            # parent models about the child (mainly port mappings)
            def overload_info
                @overload_info ||= InstanceSelection.new(nil, self, @parent_model || InstanceRequirements.new)
            end
            # @return [CompositionChild,nil] the composition child model from which
            #   this model has been overloaded
            attr_accessor :parent_model

            # If set to true, the child is going to be removed automatically if
            # no selection exists for it
            attr_predicate :optional?

            def initialize(composition_model, child_name, models = Set.new, dependency_options = {},
                parent_model = nil)
                @composition_model = composition_model
                @child_name = child_name
                super(models)
                @dependency_options = Roby::TaskStructure::Dependency.validate_options(dependency_options)
                @parent_model = parent_model
            end

            def initialize_copy(old)
                super
                @dependency_options = old.dependency_options.dup
                @overload_info = nil
            end

            def freeze
                # Precompute memoized values, or we'll get a frozen error
                overload_info
                super
            end

            def eql?(other)
                other.respond_to?(:child_name) && other.child_name == child_name &&
                    super
            end

            # @deprecated use {#try_resolve_and_bind_child} instead
            def try_resolve_child(task)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                    "CompositionChild#try_resolve_and_bind_child instead"
                try_resolve_and_bind_child(task)
            end

            # @deprecated use {#try_resolve_and_bind_child_recursive} instead
            def try_resolve_child_recursive(root)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                    "CompositionChild#try_resolve_and_bind_child_recursive instead"
                try_resolve_and_bind_child_recursive(root)
            end

            # @deprecated use {#resolve_and_bind_child} instead
            def resolve_child(task)
                Roby.warn_deprecated "#{__method__} is deprecated, "\
                    "use #resolve_and_bind_child instead"
                resolve_and_bind_child(task)
            end

            # Tries to resolve the task that corresponds to self starting the
            # resolution at the given root
            #
            # If {#composition_model} is not itself a CompositionChild, this is
            # equivalent to {#try_resolve_and_bind_child}. Otherwise, it
            # resolves the children one by one starting at the given root.
            #
            # @return [nil,Object]
            def try_resolve_and_bind_child_recursive(root)
                # Handle a composition child of a composition child
                if composition_model.respond_to?(:try_resolve_and_bind_child_recursive)
                    resolved_parent = composition_model
                                      .try_resolve_and_bind_child_recursive(root)

                    try_resolve_and_bind_child(resolved_parent) if resolved_parent
                else
                    try_resolve_and_bind_child(root)
                end
            end

            # Resolves the task that corresponds to self starting the
            # resolution at the given root
            #
            # If {#composition_model} is not itself a CompositionChild, this is
            # equivalent to {#resolve_and_bind_child}. Otherwise, it
            # resolves the children one by one starting at the given root.
            #
            # @return [Object]
            # @raise [ArgumentError] if the root is not suitable for the resolution
            #   (e.g. wrong model or missing children)
            def resolve_and_bind_child_recursive(root)
                if bound = try_resolve_and_bind_child_recursive(root)
                    bound
                else
                    raise ArgumentError, "cannot resolve #{self} from #{root}"
                end
            end

            # Resolves the instance that matches self in the given composition
            #
            # The method binds the instance to self with {#bind}. This means
            # that the returned value offers the interface that {#model} expects,
            # and not necessarily the one of the actual instance.
            #
            # For instance, if self represents a data service, it will return
            # the corresponding {Syskit::BoundDataService}
            #
            # @param [Syskit::Composition] composition the composition instance
            #   whose child we are trying to resolve
            # @return [nil,Object] the bound children instance, or
            #   nil if it cannot be resolved
            def try_resolve_and_bind_child(composition)
                if bound = composition_model.try_bind(composition)
                    bound.find_required_composition_child_from_role(
                        child_name, composition_model
                    )
                end
            end

            # Resolves the task instance that corresponds to self, using +task+
            # as the root composition. The returned instance is bound to self.
            #
            # @return [Roby::Task]
            # @raise [ArgumentError] if task does not fullfill the required
            #   composition model, or if it does not have the required children
            #
            # @see InstanceRequirements#bind
            def resolve_and_bind_child(task)
                if resolved_task = try_resolve_and_bind_child(task)
                    resolved_task
                else
                    raise ArgumentError, "cannot find #{self} from #{task}"
                end
            end

            # Binds this child model to the component
            #
            # Within Syskit, binding a model to an instance means returning a
            # 'view' of the instance that is described by the model. For
            # instance, if the child is defined by a service, the returned
            # object will be a {Syskit::BoundDataService} instance, which
            # then allows to for instance resolve ports "as if" they were
            # from the service itself.
            #
            # @param [Syskit::Component,Syskit::BoundDataService] component
            #   the component instance
            # @return [Syskit::Component,Syskit::BoundDataService] the bound
            #   data service.
            # @raise if self cannot be bound to the component, usually because
            #   the component is not the "right" child from the composition
            def bind(component_or_service)
                case component_or_service
                when Syskit::BoundDataService
                    # We still got to make sure that the service is from the
                    # "right" child, and that it is actually compatible with
                    # the child model
                    bind_resolve_parent(component_or_service.component)
                    super(component_or_service)
                else
                    parent = bind_resolve_parent(component_or_service)
                    resolve_and_bind_child(composition_model.bind(parent))
                end
            end

            def bind_resolve_parent(component)
                compositions =
                    component
                    .each_parent_task
                    .find_all { |t| t.fullfills?(composition_model) }

                parent =
                    compositions
                    .find { |t| component == t.find_child_from_role(child_name) }

                return parent if parent

                if compositions.empty?
                    raise ArgumentError,
                          "cannot bind #{self} to #{component}: it is not the child "\
                          "of any #{composition_model} composition"
                else
                    raise ArgumentError,
                          "cannot bind #{self} to #{component}: it is the child of "\
                          "one or more #{composition_model} compositions, but not "\
                          "with the role '#{child_name}'"
                end
            end

            # The port mappings from this child's parent model to this model
            def port_mappings
                overload_info.port_mappings
            end

            def optional
                @optional = true
            end

            # Automatically computes the connections between the output ports of
            # self to the given port or component interface
            #
            # @param [Port,CompositionChild] the sink side of the connection. If
            #   a Port is given, it has to be a port on a CompositionChild of
            #   the same composition than self
            # @return [Array<Port>] the set of created connections
            def connect_to(sink, policy = {})
                Syskit.connect(self, sink, policy)
            end

            # Test whether the given port object is a port of self
            #
            # @param [Port] port
            def self_port?(port)
                port.component_model == self
            end

            # @api private
            #
            # Tests whether two ports are connected
            #
            # This is a delegated call from Port#connected_to?. Always use the
            # former unless you know what you are doing
            def connected?(source_port, sink_port)
                if !self_port?(source_port)
                    raise ArgumentError, "source port #{source_port} in connected? is not a port of #{self}"
                elsif !composition_model.child_port?(sink_port)
                    return false
                end

                cmp_connections = composition_model
                                  .explicit_connections[[child_name, sink_port.component_model.child_name]]
                cmp_connections.key?([source_port.name, sink_port.name])
            end

            # (see Component#connect_ports)
            def connect_ports(other_component, connections)
                if !other_component.respond_to?(:composition_model)
                    raise ArgumentError, "cannot connect ports of #{self} to ports of #{other_component}: #{other_component} is not a composition child"
                elsif other_component.composition_model != composition_model
                    raise ArgumentError, "cannot connect ports of #{self} to ports of #{other_component}: they are children of different composition models"
                end

                cmp_connections = composition_model.explicit_connections[[child_name, other_component.child_name]]
                connections.each do |port_pair, policy|
                    cmp_connections[port_pair] = policy
                end
            end

            def ==(other) # :nodoc:
                other.class == self.class &&
                    other.composition_model == composition_model &&
                    other.child_name == child_name
            end

            def state
                if @state
                    @state
                elsif component_model = models.find { |c| c <= Component }
                    @state = Roby::StateFieldModel.new(component_model.state)
                    @state.__object = self
                    @state
                else
                    raise ArgumentError, "cannot create a state model on elements that are only data services"
                end
            end

            def to_s
                "#{composition_model}.#{child_name}_child[#{super}]"
            end

            def pretty_print(pp)
                pp.text "child #{child_name} of type "
                super
                pp.breakable
                pp.text "of #{composition_model}"
            end

            def short_name
                "#{composition_model.short_name}.#{child_name}_child[#{model.short_name}]"
            end

            def attach(composition_model)
                result = dup
                result.instance_variable_set :@composition_model, composition_model
                result
            end

            def to_instance_requirements
                ir = InstanceRequirements.new
                ir.do_copy(self)
                ir
            end
        end

        class InvalidCompositionChildPort < RuntimeError
            attr_reader :composition_model
            attr_reader :child_name
            attr_reader :port_name
            attr_reader :existing_ports

            def initialize(composition_model, child_name, port_name)
                @composition_model = composition_model
                @child_name = child_name
                @port_name = port_name
                @existing_ports = composition_model.find_child(child_name).each_required_model.map do |child_model|
                    [child_model, child_model.each_input_port.sort_by(&:name), child_model.each_output_port.sort_by(&:name)]
                end
            end

            def pretty_print(pp)
                pp.text "port #{port_name} of child #{child_name} of #{composition_model.short_name} does not exist"
                pp.breakable
                pp.text "Available ports are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(existing_ports) do |child_model, inputs, outputs|
                        pp.text child_model.short_name
                        pp.nest(2) do
                            pp.breakable
                            pp.seplist(inputs) do |port|
                                pp.text "(in)#{port.name}[#{port.type_name}]"
                            end
                            pp.breakable
                            pp.seplist(outputs) do |port|
                                pp.text "(out)#{port.name}[#{port.type_name}]"
                            end
                        end
                    end
                end
            end
        end
    end
end
