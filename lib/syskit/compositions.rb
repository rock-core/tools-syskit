module Orocos
    module RobyPlugin
        class CompositionChild
            attr_reader :composition, :child_name
            def initialize(composition, child_name)
                @composition = composition
                @child_name  = child_name
            end

            def model
                composition.children[child_name]
            end

            def method_missing(name, *args)
                if args.empty?
                    composition.find_child(child_name).each do |m|
                        if port = m.port(name)
                            return CompositionChildPort.new(self, port, name.to_str)
                        end
                    end
                end

                raise NoMethodError, "child #{child_name}[#{composition.find_child(child_name).to_a.join(", ")}] of #{composition} has no port named #{name}", caller(1)
            end

            def ==(other)
                other.composition == composition &&
                    other.child_name == child_name
            end
        end

        class CompositionChildPort
            # The child object this port is part of
            attr_reader :child
            # The port object that describes the actual port
            attr_reader :port
            # The actual port name. Can be different from port.name
            # in case of port exports (in compositions) and port aliasing
            attr_reader :port_name

            # The port name
            #
            # See #port_name
            def name; port_name end

            # The port's type name
            def type_name
                port.type_name
            end

            def initialize(child, port, port_name)
                @child = child
                @port  = port
                @port_name = port_name
            end

            def ==(other)
                other.child == child &&
                    other.port == port &&
                    other.port_name == port_name
            end
        end

        module CompositionModel
            include Model

            attr_accessor :name

            def new_submodel(name, system)
                klass = super()
                klass.name = name
                klass.system = system
                klass
            end

            def [](name)
                name = name.to_str 
                if find_child(name)
                    CompositionChild.new(self, name)
                end
            end

            def add_child(name, child_model)
                if !child_model.respond_to?(:to_ary)
                    child_model = [child_model]
                end

                name = name.to_str
                if children[name]
                    raise ArgumentError, "this composition has a child named '#{name}' already"
                end

                child_task_model = child_model.find_all { |m| m < Component }
                if child_task_model.size > 1
                    raise SpecError, "more than one task model specified for #{name}"
                end
                child_task_model = child_task_model.first

                parent_model = find_child(name) || Array.new
                if child_task_model
                    parent_task_model = parent_model.find { |m| m < Component }
                    if parent_task_model && !(child_task_model <= parent_task_model)
                        raise SpecError, "trying to overload #{parent_model} with #{child_model}"
                    end
                end

                # Delete from +parent_model+ everything that is already included
                # in +child_model+
                result = parent_model.dup
                result.delete_if { |parent_m| child_model.any? { |child_m| child_m <= parent_m } }
                children[name] = result.to_value_set | child_model.to_value_set
            end

            def add(model, options = Hash.new)
                if !model.kind_of?(Roby::TaskModelTag) && !(model.kind_of?(Class) && model < Component)
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
                options = Kernel.validate_options options, :as => model.name.gsub(/.*::/, '')

                add_child(options[:as], model)
                CompositionChild.new(self, options[:as])
            end

            def constrain(child, allowed_models)
                child = if child.respond_to?(:to_str)
                            child.to_str
                        else child.name.gsub(/.*::/, '')
                        end

                allowed_models.each do |m|
                    specialize(child, m)
                end
                child_constraints[child].concat( allowed_models )
                self
            end

            Specialization = Struct.new :specialized_children, :composition

            def specialize(child_name, child_model, &block)
                child_name = if child_name.respond_to?(:to_str)
                                 child_name.to_str
                             else
                                 child_name.name.gsub(/^.*::/, '')
                             end

                # Make sure we actually specialize ...
                if !has_child?(child_name)
                    raise SpecError, "there is no child called #{child_name} in #{self}"
                end
                parent_model = find_child(child_name)
                if parent_model.any? { |m| m <= child_model }
                    raise SpecError, "#{child_model} does not specify a specialization of #{parent_model}"
                end

                submodel_name = "#{name}_#{child_name}_#{child_model.name}"
                if submodel_name !~ /^Anon/
                    submodel_name = "Anon#{submodel_name}"
                end
                child_composition = system.composition(
                        submodel_name,
                        :child_of => self) do
                    add child_model, :as => child_name
                end
                
                specializations <<
                    Specialization.new({ child_name => child_model }, child_composition)
                if block_given?
                    child_composition.instance_eval(&block)
                end

                # Apply the specialization to the existing ones
                specializations.each do |spec|
                    if spec.composition != child_composition
                        spec.composition.specialize(child_name, child_model, &block)
                    end
                end
                child_composition
            end

            # Returns true if +model1+ is a specialization of +model2+
            def is_specialized_model(model1, model2)
                model2.each do |m2|
                    is_specialized_in_model1 = model1.any? do |m1|
                        m1 <= m2
                    end
                    return if !is_specialized_in_model1
                end
                true
            end

            # Returns the composition models from model_set that are the most
            # specialized in the context of +selected_children+.
            def find_most_specialized_compositions(model_set, selected_children)
                # Build the association of +composition+ and the matching models
                # in +composition+.
                #
                # The result is an array of 2-tuples
                #  [composition_model, children_models]
                #
                # where children_models is
                #  child_name => child_model, child_name => child_model
                dependent_models = model_set.map do |composition|
                    models = composition.each_child.
                        inject(Hash.new) do |h, (child_name, child_model)|
                            if selected_children.has_key?(child_name)
                                h[child_name] = child_model
                            end
                            h
                        end
                    [composition, models]
                end

                # Find the most specialized compositions by deleting the ones
                # for which at least one of the children
                dependent_models.delete_if do |composition, models|
                    dependent_models.any? do |other_composition, other_models|
                        next if other_composition == composition
                        models.each_key.all? do |child_name|
                            is_specialized_model(other_models[child_name], models[child_name])
                        end
                    end
                end

                dependent_models.map { |c, _| c }
            end

            # Returns the set of specializations of +self+ that apply to
            # +selected_models+. Only the most specialized compositions are
            # returned.
            def find_specializations(selected_models)
                # Select in our specializations the ones that match the current
                # selection. To do that, we simply have to find those for which
                # +selected_models+ is an acceptable selection.
                candidates = specializations.map { |spec| spec.composition }.
                    find_all do |child_composition|
                        # Note that the 'new' models in +child_composition+ are
                        # all in child_composition.children
                        child_composition.children.all? do |child_name, child_model|
                            selected_model = selected_models[child_name]
                            # new child in +child_composition+, do not count
                            next(true) if !selected_model
                            selected_model.first.fullfills?(child_model)
                        end
                    end

                # Add them all to +result+
                candidates = candidates.inject(candidates.dup) do |r, composition|
                    r.concat(composition.find_specializations(selected_models))
                end

                find_most_specialized_compositions(candidates, selected_models)
            end

            def autoconnect(*names)
                @autoconnect = if names.empty? 
                                   each_child.map { |n, _| n }
                               else names
                               end

                specializations.each do |spec|
                    spec.composition.autoconnect
                end
            end

            def compute_autoconnection
                if @autoconnect && !@autoconnect.empty?
                    do_autoconnect(@autoconnect)
                end
            end

            # Automatically compute the connections that can be done in the
            # limits of this composition, and returns the set.
            #
            # Connections are determined by port direction and type name.
            #
            # It raises AmbiguousConnections if autoconnection does not know
            # what to do.
            def do_autoconnect(children_names)
                result = Hash.new { |h, k| h[k] = Hash.new }
                child_inputs  = Hash.new { |h, k| h[k] = Array.new }
                child_outputs = Hash.new { |h, k| h[k] = Array.new }

                # Gather all child input and outputs
                children_names.each do |name|
                    dependent_models = find_child(name)
                    seen = Set.new
                    dependent_models.each do |sys|
                        sys.each_input do |in_port|
                            if !seen.include?(in_port.name) && !exported_port?(in_port)
                                child_inputs[in_port.type_name] << [name, in_port.name]
                                seen << in_port.name
                            end
                        end

                        sys.each_output do |out_port|
                            if !seen.include?(out_port.name) && !exported_port?(out_port)
                                child_outputs[out_port.type_name] << [name, out_port.name]
                                seen << out_port.name
                            end
                        end
                    end
                end

                # Make sure there is only one input for one output, and add the
                # connections
                child_inputs.each do |typename, in_ports|
                    in_ports.each do |in_child_name, in_port_name|
                        out_ports = child_outputs[typename]
                        out_ports.delete_if do |out_child_name, out_port_name|
                            out_child_name == in_child_name
                        end
                        next if out_ports.empty?

                        if out_ports.size > 1
                            # Check for port name
                            same_name = out_ports.find_all { |_, out_port_name| out_port_name == in_port_name }
                            if same_name.size == 1
                                out_ports = same_name
                            end
                        end

                        if out_ports.size > 1
                            out_port_names = out_ports.map { |child_name, port_name| "#{child_name}.#{port_name}" }
                            raise Ambiguous, "multiple output candidates in #{name} for #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
                        end

                        out_port = out_ports.first
                        result[[out_port[0], in_child_name]][ [out_port[1], in_port_name] ] = Hash.new
                    end
                end

                self.automatic_connections = result
            end

            def connections
                result = Hash.new { |h, k| h[k] = Hash.new }
                # In the following, 'key' is [child_source, child_dest] and
                # 'mappings' is [port_source, port_sink] => connection_policy
                each_automatic_connection do |key, mappings|
                    result[key].merge!(mappings)
                end
                each_explicit_connection do |key, mappings|
                    result[key].merge!(mappings)
                end
                result
            end

            def export(port, options = Hash.new)
                options = Kernel.validate_options options, :as => port.name
                name = options[:as].to_str
                if self.port(name)
                    raise SpecError, "there is already a port named #{name} on #{self}"
                end

                case port.port
                when Generation::OutputPort
                    outputs[name] = port
                when Generation::InputPort
                    inputs[name] = port
                else
                    raise TypeError, "invalid port #{port.port} of type #{port.port.class}"
                end
            end

            def port(name)
                name = name.to_str
                output_port(name) || input_port(name)
            end

            def output_port(name); find_output(name) end
            def input_port(name); find_input(name) end
            def dynamic_input_port?(name); false end
            def dynamic_output_port?(name); false end

            def exported_port?(port_model)
                each_output.find { |_, p| port_model == p } ||
                    each_input.find { |_, p| port_model == p }
            end

            def connect(mappings)
                options = Hash.new
                mappings.delete_if do |a, b|
                    if a.respond_to?(:to_str)
                        options[a] = b
                    end
                end
                if !options.empty?
                    options = Kernel.validate_options options, Orocos::Port::CONNECTION_POLICY_OPTIONS
                end
                mappings.each do |out_p, in_p|
                    explicit_connections[[out_p.child.child_name, in_p.child.child_name]][ [out_p.name, in_p.name] ] = options
                end
            end

            def apply_port_mappings(connections, child_name, port_mappings)
                connections.each do |(out_name, in_name), mappings|
                    mapped_connections = Hash.new

                    if out_name == child_name
                        mappings.delete_if do |(out_port, in_port), options|
                            if mapped_port = port_mappings[out_port]
                                mapped_connections[ [in_port, mapped_port] ] = options
                            end
                        end

                    elsif in_name == child_name
                        mappings.delete_if do |(out_port, in_port), options|
                            if mapped_port = port_mappings[in_port]
                                mapped_connections[ [mapped_port, out_port] ] = options
                            end
                        end
                    end
                    mappings.merge!(mapped_connections)
                end
                connections
            end

            def constraints_for(child_name)
                result = ValueSet.new
                each_child_constraint(child_name, false) do |constraint_set|
                    result |= constraint_set.to_value_set
                end
                result
            end

            # In the explicit selection phase, try to find a composition that
            # matches +selection+ for +child_name+
            def find_selected_compositions(engine, child_name, selection)
                subselection = Hash.new
                selection_children = Array.new
                selection.each do |name, model|
                    if name =~ /^#{child_name}\.(.+)/ 
                        name = $1
                        selection_children << name.gsub(/\..*/, '')
                    end
                    subselection[name] = model
                end

                # No indirect composition selection exist
                if subselection == selection
                    return Array.new
                end

                # Find all compositions that can be used for +child_name+ and
                # for which +subselection+ is a valid selection
                candidates = engine.model.each_composition.find_all do |composition_model|
                    if !acceptable_selection?(child_name, composition_model)
                        next 
                    end
                    if !selection_children.all? { |n| composition_model.has_child?(n) }
                        next
                    end

                    begin
                        composition_model.filter_selection(engine, subselection)
                    rescue SpecError
                    end
                end

                # Now select the most specialized models
                find_most_specialized_compositions(candidates, subselection)
            end
            
            # call-seq:
            #   find_selected_model_and_task(engine, child_name, selection) => selected_object_name, child_model, child_task
            #
            # Finds a possible child model for +child_name+. +selection+ is an
            # explicit selection hash of the form
            #
            #   selection_hint => [task_name|task_model|task_instance]
            #
            # selection_hint::
            #   the selection hint can either be a child name, a child model or
            #   a child model name, with this order of precedence. The child
            #   name can be recursively specified as child1.child2.child3, to
            #   avoid broad selection. Moreover, it is possible to indirectly
            #   select a composition by using the child1.child2 => model syntax.
            #
            # selected_object::
            #   if given by name, it can either be a device name, or the name
            #   given to a task instance in Engine#add. Otherwise, it can either
            #   be a task model (as a class object) or a task instance (as a
            #   Component instance).
            #
            def find_selected_model_and_task(engine, child_name, selection)
                dependent_model = find_child(child_name)

                # First, simply check for the child's name
                selected_object = selection[child_name]

                # Now, check that if there is an explicit selection for a
                # child's child (i.e. starting with child_name.). In that
                # case, search for a matching composition
                if !selected_object
                    matching_compositions = find_selected_compositions(engine, child_name, selection)
                    if matching_compositions.size > 1
                        raise Ambiguous, "the following compositions match for #{child_name}: #{matching_compositions.map(&:to_s).join(", ")}"
                    end
                    selected_object = matching_compositions.first
                end

                # Second, look into the child model
                if !selected_object
                    candidates = dependent_model.map do |m|
                        selection[m] || selection[m.name]
                    end
                    if candidates.size > 1
                        raise Ambiguous, "there are multiple selections applying to #{child_name}: #{candidates.map(&:to_s).join(", ")}"
                    end
                    selected_object = candidates.first
                end

                if !selected_object
                    if dependent_model.size > 1
                        raise Ambiguous, "#{child_name} has to be selected explicitely"
                    end

                    # no explicit selection, just add the default one
                    selected_object = dependent_model.first
                end

                # The selection can either be a device name, a model or a
                # task instance.
                if selected_object.respond_to?(:to_str)
                    selected_object_name = selected_object.to_str
                    if !(selected_object = engine.tasks[selected_object_name])
                        raise SpecError, "#{selected_object_name} is not a device name. Compositions and tasks must be given as objects"
                    end
                end

                if selected_object.kind_of?(Component)
                    child_task  = selected_object # selected an instance explicitely
                    child_model = child_task.model
                elsif selected_object.kind_of?(DataSourceModel)
                    child_model = selected_object.task_model
                elsif selected_object < Component
                    child_model = selected_object
                else
                    raise SpecError, "invalid selection #{selected_object}: expected a device name, a task instance or a model"
                end

                return selected_object_name, child_model, child_task
            end

            # Verifies that +selected_model+ is an acceptable selection for
            # +child_name+ on +self+. Raises SpecError if it is not the case,
            # and ArgumentError if the specified child is not a child of this
            # composition.
            #
            # See also #acceptable_selection?
            def verify_acceptable_selection(child_name, selected_model)
                dependent_model = find_child(child_name)
                if !dependent_model
                    raise ArgumentError, "#{child_name} is not the name of a child of #{self}"
                end

                if !selected_model.fullfills?(dependent_model)
                    raise SpecError, "cannot select #{selected_model} for #{child_name} (#{dependent_model}): [#{selected_model}] is not a specialization of [#{dependent_model.to_a.join(", ")}]"
                end

                constraints = constraints_for(child_name)
                if !constraints.empty? && constraints.all? { |m| !selected_model.fullfills?(m) }
                    raise SpecError, "selected model #{selected_model} does not match the constraints for #{child_name}: it implements none of #{constraints.map(&:name).join(", ")}"
                end
            end

            # Returns true if +selected_child+ is an acceptable selection for
            # +child_name+ on +self+
            #
            # See also #verify_acceptable_selection
            def acceptable_selection?(child_name, selected_child)
                verify_acceptable_selection(child_name, selected_child)
                true
            rescue SpecError
                false
            end

            # Computes the port mappings required to apply the data sources in
            # +data_sources+ to a task of +child_model+. +selected_object_name+
            # is the selected object (as a string) given by the caller at
            # instanciation time. It can be of the form
            # <task_name>.<source_name>, in which case it is used to perform the
            # selection
            #
            # The returned port mapping hash is of the form
            #
            #   source_port_name => child_port_name
            #
            def compute_port_mapping_for_selection(selected_object_name, child_model, data_sources)
                port_mappings = Hash.new

                if selected_object_name
                    _, *selection_name = selected_object_name.split '.'
                    selection_name = if selection_name.empty? then nil
                                     else selection_name.join(".")
                                     end
                end

                data_sources.each do |data_source_model|
                    target_source_name = child_model.find_matching_source(data_source_model, selection_name)
                    if !child_model.main_data_source?(target_source_name)
                        mappings = DataSourceModel.compute_port_mappings(data_source_model, child_model, target_source_name)
                        port_mappings.merge!(mappings) do |key, old, new|
                            if old != new
                                raise InternalError, "two different port mappings are required"
                            end
                        end
                    end
                end
                port_mappings
            end

            # Extracts from +selection+ the specifications that are relevant for
            # +self+, and returns a list of selected models, as
            #
            #   child_name => [child_model, child_task, port_mappings]
            #
            # where +child_name+ is the name of the child, +child_model+ is the
            # actual selected model and +child_task+ the actual selected task.
            #
            # +child_task+ will be non-nil only if the user specifically
            # selected a task.
            def filter_selection(engine, selection)
                result = Hash.new
                each_child do |child_name, dependent_model|
                    selected_object_name, child_model, child_task =
                        find_selected_model_and_task(engine, child_name, selection)
                    verify_acceptable_selection(child_name, child_model)

                    # If the model is a plain data source (i.e. not a task
                    # model), we must map this source to a source on the
                    # selected task
                    data_sources  = dependent_model.find_all { |m| m < DataSource && !(m < Roby::Task) }
                    if !data_sources.empty?
                        port_mappings = compute_port_mapping_for_selection(selected_object_name, child_model, data_sources)
                    end

                    STDERR.puts " selected #{child_task || child_model} (#{port_mappings}) for #{child_name}"
                    result[child_name] = [child_model, child_task, port_mappings || Hash.new]
                end

                result
            end

            def instanciate(engine, arguments = Hash.new)
                arguments, task_arguments = Model.filter_instanciation_arguments(arguments)
                user_selection = arguments[:selection]

                # First of all, add the task for +self+
                engine.plan.add(self_task = new(task_arguments))
                self_task.robot = engine.robot

                # Apply the selection to our children
                selected_models = filter_selection(engine, user_selection)

                # Find the specializations that apply
                candidates = find_specializations(selected_models)

                # Now, check if some of our specializations apply to
                # +selected_models+. If there is one, call #instanciate on it
                if candidates.size > 1
                    candidates = candidates.map(&:name).join(", ")
                    raise Ambiguous, "more than one specialization apply: #{candidates}"
                elsif !candidates.empty?
                    return candidates[0].instanciate(engine, arguments)
                end

                # The set of connections we must create on our children. This is
                # self.connections on which port mappings rules have been
                # applied
                connections = self.connections

                # Finally, instanciate the missing tasks and add them to our
                # children
                children_tasks = Hash.new
                selected_models.each do |child_name, (child_model, child_task, port_mappings)|
                    if port_mappings
                        apply_port_mappings(connections, child_name, port_mappings)
                    end

                    role = if child_name == child_model.name.gsub(/.*::/, '')
                               Set.new
                           else [child_name].to_set
                           end

                    if !child_task
                        # Filter out arguments: check if some of the mappings
                        # are prefixed by "child_name.", in which case we
                        # transform the mapping for our child
                        child_arguments = arguments.dup
                        child_selection = Hash.new
                        arguments[:selection].each do |from, to|
                            if from.respond_to?(:to_str) && from =~ /^#{child_name}\./
                                from = $'
                            end
                            child_selection[from] = to
                        end
                        child_arguments[:selection] = child_selection
                        child_task = child_model.instanciate(engine, child_arguments)
                    end

                    children_tasks[child_name] = child_task
                    dependent_models    = find_child(child_name).to_a
                    dependent_arguments = dependent_models.inject(Hash.new) do |result, m|
                        result.merge(m.meaningful_arguments(child_task.arguments))
                    end
                    if dependent_models.size == 1
                        dependent_models = dependent_models.first
                    end
                    self_task.depends_on(child_task,
                            :model => [dependent_models, dependent_arguments],
                            :roles => role)
                end

                output_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_output do |output_name, port|
                    output_connections[ port.child.child_name ].
                        merge!([port.name, output_name] => Hash.new)
                end
                output_connections.each do |child_name, mappings|
                    children_tasks[child_name].forward_ports(self_task, mappings)
                end

                input_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_input do |input_name, port|
                    input_connections[ port.child.child_name ].
                        merge!([input_name, port.name] => Hash.new)
                end
                input_connections.each do |child_name, mappings|
                    self_task.forward_ports(children_tasks[child_name], mappings)
                end

                connections.each do |(out_name, in_name), mappings|
                    children_tasks[out_name].
                        connect_ports(children_tasks[in_name], mappings)
                end
                self_task
            end
        end

        # Module in which all composition models are registered
        module Compositions
            def self.each
                constants.each do |name|
                    yield(const_get(name))
                end
            end
        end

        class Composition < Component
            extend CompositionModel

            inherited_enumerable(:child, :children, :map => true) { Hash.new }
            inherited_enumerable(:child_constraint, :child_constraints, :map => true) { Hash.new { |h, k| h[k] = Array.new } }
            class << self
                attribute(:specializations) { Array.new }
            end

            # The set of connections specified by the user for this composition
            inherited_enumerable(:explicit_connection, :explicit_connections) { Hash.new { |h, k| h[k] = Hash.new } }
            # The set of connections automatically generated by
            # compute_autoconnection
            inherited_enumerable(:automatic_connection, :automatic_connections) { Hash.new }

            # Outputs exported from this composition
            inherited_enumerable(:output, :outputs, :map => true)  { Hash.new }
            # Inputs imported from this composition
            inherited_enumerable(:input, :inputs, :map => true)  { Hash.new }
        end
    end
end

