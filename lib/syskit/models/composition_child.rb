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
                @overload_info ||= InstanceSelection.new(self, @parent_model || InstanceRequirements.new)
            end

            # If set to true, the child is going to be removed automatically if
            # no selection exists for it
            attr_predicate :optional?

            def initialize(composition_model, child_name, models = ValueSet.new, dependency_options = Hash.new,
                          parent_model = nil)
                @composition_model, @child_name = composition_model, child_name
                super(models)
                @dependency_options = Roby::TaskStructure::Dependency.validate_options(dependency_options)
                @parent_model = parent_model
            end

            def initialize_copy(old)
                super
                @dependency_options = old.dependency_options.dup
                @overload_info = nil
            end

            # The port mappings from this child's parent model to this model
            def port_mappings
                overload_info.port_mappings
            end

            def optional
                @optional = true
            end

            def find_input_port(name)
                name = name.to_s
                candidates = []
                models.map do |child_model|
                    if port  = child_model.find_input_port(name)
                        candidates << [child_model, port]
                    end
                end

                if candidates.size > 1
                    candidates = candidates.map do |model, port|
                        "#{model.short_name}.#{port.name}"
                    end
                    raise AmbiguousChildPort.new(self, name, candidates), "#{name} is ambiguous on the child #{child_name} of #{composition_model.short_name}: #{candidates.join(", ")}"
                elsif candidates.size == 1
                    port = candidates.first[1]
                    return InputPort.new(self, port, name)
                end
                nil
            end

            def find_output_port(name)
                name = name.to_s
                candidates = []
                models.map do |child_model|
                    if port = child_model.find_output_port(name)
                        candidates << [child_model, port]
                    end
                end

                if candidates.size > 1
                    candidates = candidates.map do |model, port|
                        "#{model.short_name}.#{port.name}"
                    end
                    raise AmbiguousChildPort.new(self, name, candidates), "#{name} is ambiguous on the child #{child_name} of #{composition_model.short_name}: #{candidates.join(", ")}"
                elsif candidates.size == 1
                    port = candidates.first[1]
                    return OutputPort.new(self, port, name)
                end
                nil
            end

            def find_port(name)
                find_input_port(name) || find_output_port(name)
            end

            def each_input_port(&block)
                models.each do |child_model|
                    child_model.each_input_port do |p|
                        yield(p.attach(self))
                    end
                end
            end

            def each_output_port(&block)
                models.each do |child_model|
                    child_model.each_output_port do |p|
                        yield(p.attach(self))
                    end
                end
            end

            # Returns a CompositionChildPort instance if +name+ is a valid port
            # name
            def method_missing(name, *args) # :nodoc:
                return super if !args.empty? || block_given?

                name = name.to_s
                if name =~ /^(\w+)_port$/
                    name = $1
                    if port = find_port(name)
                        return port
                    else
                        raise InvalidCompositionChildPort.new(composition_model, child_name, name),
                            "in composition #{composition_model.short_name}: child #{child_name} of type #{models.map(&:short_name).join(", ")} has no port named #{name}", caller(1)
                    end
                end
                super
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

            def to_s # :nodoc:
                "#<CompositionChild: #{child_name} #{composition_model}>"
            end

            def short_name
                "#{composition_model.short_name}.#{child_name}_child[#{models.map(&:short_name).join(", ")}]"
            end

            def attach(composition_model)
                result = dup
                result.instance_variable_set :@composition_model, composition_model
                result
            end

            def find_child(child_name)
                composition_models = models.find_all { |m| m.respond_to?(:find_child) }
                if composition_models.empty?
                    raise ArgumentError, "#{self} is not a composition"
                end
                composition_models.each do |m|
                    if child = m.find_child(child_name)
                        return child.attach(self)
                    end
                end
            end

            def resolve(root_composition)
                root = self
                path = Array.new
                while root.respond_to?(:child_name)
                    path.unshift root.child_name
                    root = root.composition_model
                end

                task =
                    if path.size > 1
                        root_composition.child_from_role(*path[0..-2])
                    else root
                    end
                task.selected_instance_for(path[-1])
            end
        end

        class InvalidCompositionChildPort < RuntimeError
            attr_reader :composition_model
            attr_reader :child_name
            attr_reader :child_model
            attr_reader :port_name

            def initialize(composition_model, child_name, port_name)
                @composition_model, @child_name, @port_name =
                    composition_model, child_name, port_name
                @child_model = composition_model.find_child(child_name).models.dup
            end

            def pretty_print(pp)
                pp.text "port #{port_name} of child #{child_name} of #{composition_model.short_name} does not exist"
                pp.breakable
                pp.text "Available ports are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(child_model) do |model|
                        pp.text model.short_name
                        pp.nest(2) do
                            pp.breakable
                            inputs = model.each_input_port.sort_by(&:name)
                            outputs = model.each_output_port.sort_by(&:name)
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
