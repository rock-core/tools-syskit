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
            # ValueSet which contains at most one Component model and any number
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

            def initialize(composition_model, child_name, models = ValueSet.new, dependency_options = Hash.new,
                          parent_model = nil)
                @composition_model, @child_name = composition_model, child_name
                super(models)
                @dependency_options = Roby::TaskStructure::DependencyGraphClass.validate_options(dependency_options)
                @parent_model = parent_model
            end

            def initialize_copy(old)
                super
                @dependency_options = old.dependency_options.dup
                @overload_info = nil
            end

            def eql?(other)
                other.respond_to?(:child_name) && other.child_name == child_name &&
                    super
            end

            # Tries to resolve the task that corresponds to self, using +task+ as
            # the root composition
            #
            # @return [nil,Roby::Task]
            def try_resolve(task)
                if task = composition_model.try_resolve(task)
                    return task.find_required_composition_child_from_role(child_name, composition_model)
                end
            end

            # Resolves the task that corresponds to self, using +task+ as
            # the root composition
            #
            # @return [Roby::Task]
            # @raise [ArgumentError] if task does not fullfill the required
            #   composition model, or if it does not have the required children
            def resolve(task)
                if resolved_task = try_resolve(task)
                    return resolved_task
                else
                    raise ArgumentError, "cannot find #{self} from #{task}"
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
            def connect_to(sink, policy = Hash.new)
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

                cmp_connections = composition_model.
                    explicit_connections[[child_name, sink_port.component_model.child_name]]
                cmp_connections.has_key?([source_port.name,sink_port.name])
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
                    return @state
                elsif component_model = models.find { |c| c <= Component }
                    @state = Roby::StateFieldModel.new(component_model.state)
                    @state.__object = self
                    return @state
                else
                    raise ArgumentError, "cannot create a state model on elements that are only data services"
                end
            end

            def to_s; "#{composition_model}.#{child_name}_child[#{super}]" end

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

            def bind(component)
                composition = composition_model.bind(component.parent_task)
                composition.find_required_composition_child_from_role(
                    child_name, composition_model.to_component_model)
            end

            def method_missing(name, *args)
                return super if !args.empty? || block_given?

                name = name.to_s
                if name =~ /^(\w+)_port$/
                    name = $1
                    if port = find_port(name)
                        return port
                    else
                        raise InvalidCompositionChildPort.new(composition_model, child_name, name),
                            "in composition #{composition_model.short_name}: child #{child_name} of type #{model} has no port named #{name}", caller(1)
                    end
                end
                super
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
                @composition_model, @child_name, @port_name =
                    composition_model, child_name, port_name
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
