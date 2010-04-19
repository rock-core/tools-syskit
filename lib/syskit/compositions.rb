module Orocos
    module RobyPlugin
        # Represents a placeholder in a composition
        #
        # Compostion#add returns an instance of CompostionChild to represent the
        # non-instanciated composition child. It is mainly meant to be used to
        # access port definitions:
        #
        #   source = add Source
        #   sink   = add Sink
        #   source.port.connect_to sink.port
        #
        class CompositionChild
            # The composition this child is defined on
            attr_reader :composition
            # The child name
            attr_reader :child_name

            def initialize(composition, child_name)
                @composition = composition
                @child_name  = child_name
            end

            # Returns the required model for this compostion child
            def model
                composition.find_child(child_name)
            end

            # Returns a CompositionChildPort instance if +name+ is a valid port
            # name
            def method_missing(name, *args) # :nodoc:
                if args.empty?
                    composition.find_child(child_name).each do |child_model|
                        if port = child_model.output_port(name)
                            return CompositionChildOutputPort.new(self, port, name.to_str)
                        elsif port = child_model.input_port(name)
                            return CompositionChildInputPort.new(self, port, name.to_str)
                        end
                    end
                end

                raise NoMethodError, "child #{child_name}[#{composition.find_child(child_name).to_a.join(", ")}] of #{composition} has no port named #{name}", caller(1)
            end

            def ==(other) # :nodoc:
                other.composition == composition &&
                    other.child_name == child_name
            end
        end

        # Represents a port for a composition child, at the model level. It is
        # the value returned by CompositionChildPort.port_name, and can be used
        # to set up the data flow at the composition model level:
        #
        #   source = add Source
        #   sink   = add Sink
        #   source.port.connect_to sink.port
        #   # source.port and sink.port are both CompositionChildPort instances
        #
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

            def ==(other) # :nodoc:
                other.child == child &&
                    other.port == port &&
                    other.port_name == port_name
            end
        end

        # Specialization of CompositionChildPort for output ports
        class CompositionChildOutputPort < CompositionChildPort; end
        # Specialization of CompositionChildPort for input ports
        class CompositionChildInputPort  < CompositionChildPort; end

        # Model-level instances and attributes for compositions
        #
        # See the documentation of Model for an explanation of the *Model
        # modules.
        module CompositionModel
            include Model

            # The composition model name
            attr_accessor :name

            # Creates a submodel of this model, in the frame of the given
            # SystemModel instance.
            def new_submodel(name, system)
                klass = super()
                klass.name = name
                klass.system = system
                klass
            end


            #--
            # Documentation of the inherited_enumerable attributes defined on
            # Composition
            #++

            ##
            # :method: each_child { |child_name, child_models| ... }
            # 
            # Yields all children defined on this composition. +child_models+ is
            # a ValueSet of task classes (subclasses of Roby::Task) and/or task
            # tags (instances of Roby::TaskModelTag)

            ##
            # :method: find_child(child_name) 
            #
            # Returns the model requirements for the given child. The return
            # value is a ValueSet of task classes (subclasses of Roby::Task)
            # and/or task tags (instances of Roby::TaskModelTag)

            ##
            # :method: each_input { |export_name, port| ... }
            #
            # Yields the input ports that are exported by this composition.
            # +export_name+ is the name of the composition's port and +port+ the
            # CompositionChildPort object that represents the port that is being
            # exported.

            ##
            # :method: each_output { |export_name, port| ... }
            #
            # Yields the output ports that are exported by this composition.
            # +export_name+ is the name of the composition's port and +port+ the
            # CompositionChildPort object that represents the port that is being
            # exported.

            ##
            # :attr: specializations
            #
            # The set of specializations defined at this level of the model
            # hierarchy, as an array of Specialization instances. See
            # #specialize for more details
            attribute(:specializations) { Array.new }

            # Returns the CompositionChild object that represents the given
            # child, or nil if it does not exist.
            def [](name)
                name = name.to_str 
                if find_child(name)
                    CompositionChild.new(self, name)
                end
            end

            # Internal helper to add a child to the composition
            #
            # Raises ArgumentError if +name+ is already used by a child
            # definition at this level of the model hierarchy:
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

            # Requires the specified child to be of the given models. It is
            # mainly used in an abstract compostion definition to force the user
            # to select a specific child model.
            def constrain(child, allowed_models, options = Hash.new)
                options = Kernel.validate_options options, :exclusive => false

                child = if child.respond_to?(:to_str)
                            child.to_str
                        else child.name.gsub(/.*::/, '')
                        end

                allowed_models.each do |model|
                    if options[:exclusive]
                        exclusions = allowed_models.dup
                        exclusions.delete(model)
                        specialize(child, model, :not => exclusions)
                    else
                        specialize(child, model)
                    end
                end

                child_constraints[child].concat( allowed_models )
                self
            end

            # Internal representation of specializations
            Specialization = Struct.new :specialized_children, :composition

            # Create a child of this composition model in which +child_name+ is
            # constrained to implement the +child_model+ interface. If a block
            # is given, it is used to set up the new composition.
            #
            # At instanciation time, this child will be preferentially selected
            # in place of the parent model in case the selected child is
            # actually of the given model. If two specializations match and are
            # not related to each other (i.e. there is not one that is less
            # abstract than the other), then an error is raised. This ambiguity
            # can be solved by declaring a default specialization with
            # #default_specialization.
            #
            # If it is known that a specialization is in conflict with another,
            # the :not option can be used. For instance, in the following code,
            # only two specialization will exist: the one in which the Control
            # child is a SimpleController and the one in which it is a
            # FourWheelController.
            #
            #   specialize 'Control', SimpleController, :not => FourWheelController do
            #   end
            #   specialize 'Control', FourWheelController, :not => SimpleController do
            #   end
            #
            # If the :not option had not been used, three specializations would
            # have been added: the same two than above, and the one case where
            # 'Control' fullfills both the SimpleController and
            # FourWheelController interfaces.
            def specialize(child_name, child_model, options = Hash.new, &block)
                options = Kernel.validate_options options, :not => []
                if !options[:not].respond_to?(:to_ary)
                    options[:not] = [options[:not]]
                end

                if child_name.kind_of?(Module)
                    candidates = each_child.find_all { |name, model| model.include?(child_name) }
                    if candidates.size == 1
                        child_name = candidates[0][0]
                    end
                end

                child_name = if child_name.respond_to?(:to_str)
                                 child_name.to_str
                             else
                                 child_name.name.gsub(/^.*::/, '')
                             end

                if block && (specialization = specializations.find { |m| m.specialized_children[child_name] == child_model })
                    apply_specialization_block(child_name, child_model, block)
                    return specialization.composition
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

                # Apply the specialization to the existing ones
                specializations.each do |spec|
                    next if spec.composition == child_composition

                    # If the user required some exclusions in the specialization
                    # chain, filter them out
                    if !options[:not].empty?
                        if child_specialization = spec.specialized_children[child_name]
                            if options[:not].any? { |model| child_specialization.fullfills?(model) }
                                next
                            end
                        end
                    end

                    spec.composition.specialize(child_name, child_model, options)
                end

                if block
                    apply_specialization_block(child_name, child_model, block)
                end
                child_composition
            end

            # Helper method used by #specialize to recursively apply definition
            # of new specializations.
            def apply_specialization_block(child_name, child_model, block) # :nodoc:
                specializations.each do |spec|
                    if spec.specialized_children[child_name] == child_model
                        spec.composition.with_module(*RobyPlugin.constant_search_path, &block)
                    else
                        spec.composition.apply_specialization_block(child_name, child_model, block)
                    end
                end
            end

            # Declares a preferred specialization in case two specializations
            # match that are not related to each other.
            #
            # In the following case:
            #
            #  composition 'ManualDriving' do
            #    specialize 'Control', SimpleController, :not => FourWheelController do
            #    end
            #    specialize 'Control', FourWheelController, :not => SimpleController do
            #    end
            #  end
            #
            # If a Control model is selected that fullfills both
            # SimpleController and FourWheelController, then there is an
            # ambiguity as both specializations apply and one cannot be
            # preferred w.r.t. the other.
            #
            # By using
            #   default_specialization 'Control' => SimpleController
            #
            # the first one will be preferred by default. The second one can
            # then be selected at instanciation time with
            #
            #   add 'ManualDriving',
            #       'Control' => controller_model.as(FourWheelController)
            def default_specialization(child, child_model)
                child = if child.respond_to?(:to_str)
                            child.to_str
                        else child.name.gsub(/.*::/, '')
                        end

                default_specializations[child] = child_model
            end

            # Returns true if +model1+ is either the same model or a
            # specialization of +model2+
            def is_specialized_model?(model1, model2)
                model2.each do |m2|
                    is_specialized_in_model1 = model1.any? do |m1|
                        m1 <= m2
                    end
                    return(false) if !is_specialized_in_model1
                end
                true
            end

            # Returns the composition models from model_set that are the most
            # specialized in the context of +selected_children+.
            def find_most_specialized_compositions(engine, model_set, selected_children)
                children_names = selected_children.keys

                result = model_set.dup

                # First, remove models based on the abstraction hierarchy
                result.delete_if do |composition|
                    result.any? do |other_composition|
                        next if composition == other_composition

                        children_names.all? do |child_name|
                            engine.composition_child_is_specialized(child_name, other_composition, composition)
                        end
                    end
                end
                result
            end

            # Returns the set of specializations of +self+ that can use the
            # models selected in +selected_models+. It filters out ambiguous
            # solutions by:
            # * returning the most specialized compositions, for the children
            #   that are listed in +selected_models+.<br/>
            #   <i>Example: we have a composition A with a child A.camera and a
            #   specialization B for which B.camera has to be a FirewireCamera
            #   model. B is also specialized into C for StereoCamera models. If
            #   +selected_models+ explicitely selects a FirewireCamera which is
            #   not a StereoCamera, find_specializations will return B. If it is
            #   a StereoCamera, then C is returned even though B would
            #   apply.</i><br/>
            # * returning the least specialized compositions for the children
            #   that are <b>not</b> listed in +selected_models+.<br/>
            #   <i>Example: let's assume that, in addition to a camera, the
            #   composition also includes an image processing module and have
            #   specializations for it. If +specialized_models+ does <b>not</b>
            #   explicitely select for an image processing component, only [B,
            #   C] will be returned even though all specializations on the image
            #   processing are valid (since selected_models does not specify
            #   anything).
            #
            # If there are ambiguities, it will prefer the specializations
            # specified by facet selection and/or default specializations. See
            # #default_specialization for more information.
            #
            # This is applied recursively, i.e. will search in
            # specializations-of-specializations
            def find_specializations(engine, selected_models)
                # Select in our specializations the ones that match the current
                # selection. To do that, we simply have to find those for which
                # +selected_models+ is an acceptable selection.
                candidates = specializations.map { |spec| spec.composition }.
                    find_all do |child_composition|
                        # Note that the 'new' models in +child_composition+ are
                        # all in child_composition.children
                        child_composition.each_child.all? do |child_name, child_model|
                            selected_model = selected_models[child_name]
                            if selected_model.respond_to?(:selected_facets)
                                selected_model = selected_model.selected_facets
                            end
                            # new child in +child_composition+, do not count
                            next(true) if !selected_model
                            selected_model.first.fullfills?(child_model)
                        end
                    end

                # Add them all to +result+
                candidates = candidates.inject(candidates.dup) do |r, composition|
                    r.concat(composition.find_specializations(engine, selected_models))
                end

                result = find_most_specialized_compositions(engine, candidates, selected_models)
                # Don't bother doing more if there is no ambiguity left
                if result.size < 2
                    return result
                end

                # The result is ambiguous, filter it out based on the default
                # specialization definition
                all_filtered_results = Hash.new
                each_default_specialization do |child_name, child_model|
                    if selected_child_model = selected_models[child_name] && selected_child_model.respond_to?(:selected_facets)
                        child_model = selected_child_model.selected_facets
                    end

                    filtered_results = []
                    result.find_all do |model|
                        if child_model = model.find_child(child_name)
                            if model.fullfills?(child_model)
                                filtered_results << model
                            end
                        end
                    end
                    if !filtered_results.empty?
                        all_filtered_results[child_name] = filtered_results
                    end
                end

                # Check if the default specialization leads to something
                # meaningful
                filtered_out = all_filtered_results.values.inject(&:&)
                if filtered_out && !filtered_out.empty?
                    return filtered_out
                else
                    return result
                end
            end

            # call-seq:
            #   autoconnect
            #   autoconnect 'child1', 'child2'
            #
            # In the first form, declares that all children added so far should
            # be automatically connected. In the second form, only the listed
            # children will.
            #
            # Note that ports for which an explicit connection is specified
            # (using #connect) are ignored.
            #
            # Autoconnection matches inputs and outputs of the listed children
            # to find out matching connections.
            # 1. port types are matched, i.e. inputs and outputs of the same
            #    type are candidates for autoconnection.
            # 2. if multiple connections are possible between two components,
            #    then a name filter is used: i.e. a connection will be created
            #    only for ports that have the same name.
            #
            def autoconnect(*names)
                @autoconnect = if names.empty? 
                                   each_child.map { |n, _| n }
                               else names
                               end

                specializations.each do |spec|
                    spec.composition.autoconnect
                end
            end

            # The result of #compute_autoconnection is cached. This method
            # resets the value so that the next call to #compute_autoconnection
            # does trigger a recompute
            def reset_autoconnection
                self.automatic_connections = nil
                if superclass.respond_to?(:reset_autoconnection)
                    superclass.reset_autoconnection
                end
            end

            # Computes the connections specified by #autoconnect
            def compute_autoconnection(force = false)
                if superclass.respond_to?(:compute_autoconnection)
                    superclass.compute_autoconnection(force)
                end

                if @autoconnect && !@autoconnect.empty?
                    if force || !automatic_connections
                        do_autoconnect(@autoconnect)
                    end
                else
                    self.automatic_connections = Hash.new
                end
            end

            # Automatically compute connections between the childrens listed in
            # children_names. The connections are first determined by port
            # direction and type, and then disambiguated by port name. An input
            # port will never be connected by this method to more than one
            # output.
            #
            # If an input port is involved in an explicit connection, it will
            # be ignored.
            #
            # It raises Ambiguous if there is more than one candidate for an
            # input port.
            def do_autoconnect(children_names)
                result = Hash.new { |h, k| h[k] = Hash.new }

                # First, gather per-type available inputs and outputs. Both
                # hashes are:
                #
                #   port_type_name => [[child_name, child_port_name], ...]
                child_inputs  = Hash.new { |h, k| h[k] = Array.new }
                child_outputs = Hash.new { |h, k| h[k] = Array.new }
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

                # Now create the connections
                child_inputs.each do |typename, in_ports|
                    in_ports.each do |in_child_name, in_port_name|
                        # Ignore this port if there is an explicit inbound connection that involves it
                        has_explicit_connection = each_explicit_connection.any? do |(child_source, child_dest), mappings|
                            child_source == in_child_name && mappings.keys.find { |p, _| p == in_port_name }
                        end
                        next if has_explicit_connection

                        # Now remove the potential connections to the same child
                        out_ports = child_outputs[typename]
                        out_ports.delete_if do |out_child_name, out_port_name|
                            out_child_name == in_child_name
                        end
                        next if out_ports.empty?

                        # If it is ambiguous, check first if there is only one
                        # candidate that has the same name. If there is one,
                        # pick it. Otherwise, raise an Ambiguous exception
                        if out_ports.size > 1
                            # Check for port name
                            same_name = out_ports.find_all { |_, out_port_name| out_port_name == in_port_name }
                            if same_name.size == 1
                                out_ports = same_name
                            else
                                out_port_names = out_ports.map { |child_name, port_name| "#{child_name}.#{port_name}" }
                                raise Ambiguous, "multiple output candidates in #{name} for #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
                            end
                        end

                        out_port = out_ports.first
                        result[[out_port[0], in_child_name]][ [out_port[1], in_port_name] ] = Hash.new
                    end
                end

                RobyPlugin.debug do
                    RobyPlugin.debug "Automatic connections in #{self}"
                    result.each do |(out_child, in_child), connections|
                        connections.each do |(out_port, in_port), policy|
                            RobyPlugin.debug "    #{out_child}:#{out_port} => #{in_child}:#{in_port} (#{policy})"
                        end
                    end
                    break
                end

                self.automatic_connections = result
            end

            # Returns the set of connections that should be created during the
            # instanciation of this composition model.
            #
            # The returned value is a mapping:
            #
            #   [source_name, sink_name] =>
            #       {
            #           [source_port_name0, sink_port_name1] => connection_policy,
            #           [source_port_name0, sink_port_name1] => connection_policy
            #       }
            #       
            def connections
                result = Hash.new { |h, k| h[k] = Hash.new }

                compute_autoconnection

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

            # Export the given port to the boundary of the composition (it
            # becomes a composition port). By default, the composition port has
            # the same name than the exported port. This name can be overriden
            # by the :as option
            #
            # For example, if one does:
            #    
            #    composition 'Test' do
            #       source = add 'Source'
            #       export source.output
            #       export source.output, :as => 'output2'
            #    end
            #
            # Then the resulting composition gets 'output' and 'output2' output
            # ports that can further be used in other connections (or
            # autoconnections):
            #    
            #    composition 'Global' do
            #       test = add 'Test'
            #       c = add 'Component'
            #       connect test.output2 => c.input
            #    end
            #
            def export(port, options = Hash.new)
                options = Kernel.validate_options options, :as => port.name
                name = options[:as].to_str
                if self.port(name)
                    raise SpecError, "there is already a port named #{name} on #{self}"
                end

                case port
                when CompositionChildInputPort
                    inputs[name] = port
                when CompositionChildOutputPort
                    outputs[name] = port
                else
                    raise TypeError, "invalid port #{port.port} of type #{port.port.class}"
                end
            end

            # Returns true if +port_model+, which has to be a child's port, is
            # exported in this composition
            #
            # See #export
            #
            # Example usage:
            #
            #   child = Compositions::Test['Source']
            #   Compositions::Test.exported_port?(child.output)
            def exported_port?(port_model)
                each_output.find { |_, p| port_model == p } ||
                    each_input.find { |_, p| port_model == p }
            end

            # Returns the port named 'name' in this composition
            #
            # See #export to create ports on a composition
            def port(name)
                name = name.to_str
                output_port(name) || input_port(name)
            end

            # Returns the composition's output port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def output_port(name); find_output(name.to_str) end

            # Returns the composition's input port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def input_port(name); find_input(name.to_str) end

            # Returns true if +name+ is a valid dynamic input port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def dynamic_input_port?(name); false end

            # Returns true if +name+ is a valid dynamic output port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def dynamic_output_port?(name); false end

            # Explicitly create the given connections between children of this
            # composition.
            #
            # Example:
            #   composition 'Test' do
            #       source = add 'Source'
            #       sink   = add 'Sink'
            #       connect source.output => sink.input, :type => :buffer
            #   end
            #
            # Explicit connections always have precedence on automatic
            # connections. See #autoconnect for automatic connection handling
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

            def apply_port_mappings(connections, child_name, port_mappings) # :nodoc:
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

            # Returns the set of constraints that exist for the given child.
            # I.e. the set of types that, at instanciation time, the chosen
            # child must provide.
            #
            # See #constrain
            def constraints_for(child_name)
                result = ValueSet.new
                each_child_constraint(child_name, false) do |constraint_set|
                    result |= constraint_set.to_value_set
                end
                result
            end

            # In the explicit selection phase, try to find a composition that
            # matches +selection+ for +child_name+
            def find_selected_compositions(engine, child_name, selection) # :nodoc:
                subselection = selection.dup
                selection_children = Array.new
                selection.each do |name, model|
                    next if !name.respond_to?(:to_str)
                    if name =~ /^#{child_name}\.(.+)/ 
                        subselection.delete(name)
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
                    if !selection_children.all? { |n| composition_model.all_children.has_key?(n) }
                        next
                    end

                    valid = catch :invalid_selection do
                        verify_acceptable_selection(child_name, composition_model, false)
                        true
                    end
                    next if !valid

                    valid = catch :invalid_selection do
                        composition_model.filter_selection(engine, subselection, false)
                        true
                    end
                    valid
                end

                # Now select the most specialized models
                result = find_most_specialized_compositions(engine, candidates, subselection)
                # Don't bother going further if there is no ambiguity
                if result.size < 2
                    return result
                end

                # First of all, check if we can disambiguate by using the
                # selection facets (see FacetedModelSelection and
                # ComponentModel#as)
                subselection.each do |child_name, selected_child_model|
                    next if !selected_child_model.respond_to?(:selected_facet)
                    result.delete_if do |model|
                        (child_model = model.find_child(child_name).to_a) &&
                            !child_model.any? { |m| m.fullfills?(selected_child_model.selected_facet) }
                    end
                end

                default_model = find_default_specialization(child_name)
                if default_model
                    default_selection = result.find_all { |model| model.fullfills?(default_model) }
                    if !default_selection.empty?
                        return default_selection
                    end
                end
                result
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
            def find_selected_model_and_task(engine, child_name, selection) # :nodoc:
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
            def verify_acceptable_selection(child_name, selected_model, user_call = true) # :nodoc:
                dependent_model = find_child(child_name)
                if !dependent_model
                    raise ArgumentError, "#{child_name} is not the name of a child of #{self}"
                end

                if !selected_model.fullfills?(dependent_model)
                    throw :invalid_selection if !user_call
                    raise SpecError, !user_call || "cannot select #{selected_model} for #{child_name} (#{dependent_model}): [#{selected_model}] is not a specialization of [#{dependent_model.to_a.join(", ")}]"
                end

                constraints = constraints_for(child_name)
                if !constraints.empty? && constraints.all? { |m| !selected_model.fullfills?(m) }
                    throw :invalid_selection if !user_call
                    raise SpecError, !user_call || "selected model #{selected_model} does not match the constraints for #{child_name}: it implements none of #{constraints.map(&:name).join(", ")}"
                end
            end

            # Returns true if +selected_child+ is an acceptable selection for
            # +child_name+ on +self+
            #
            # See also #verify_acceptable_selection
            def acceptable_selection?(child_name, selected_child) # :nodoc:
                catch :invalid_selection do
                    verify_acceptable_selection(child_name, selected_child, false)
                    return true
                end
                return false
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
            def compute_port_mapping_for_selection(selected_object_name, child_model, data_sources) # :nodoc:
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
            def filter_selection(engine, selection, user_call = true) # :nodoc:
                result = Hash.new
                each_child do |child_name, dependent_model|
                    selected_object_name, child_model, child_task =
                        find_selected_model_and_task(engine, child_name, selection)
                    verify_acceptable_selection(child_name, child_model, user_call)

                    # If the model is a plain data source (i.e. not a task
                    # model), we must map this source to a source on the
                    # selected task
                    data_sources  = dependent_model.find_all { |m| m < DataSource && !(m < Roby::Task) }
                    if !data_sources.empty?
                        port_mappings = compute_port_mapping_for_selection(selected_object_name, child_model, data_sources)
                    end

                    Engine.debug { " selected #{child_task || child_model} (#{port_mappings}) for #{child_name}" }
                    result[child_name] = [child_model, child_task, port_mappings || Hash.new]
                end

                result
            end

            # Cached set of all the children definitions for this composition
            # model. This is updated by #update_all_children
            #
            # It can be used to limit the impact of using #find_child, which
            # requires a traversal of the model ancestry.
            attr_reader :all_children

            # Updates the #all_children hash
            def update_all_children
                @all_children = Hash.new
                each_child do |name, model|
                    @all_children[name] = model
                end
                all_children
            end

            # Returns a Composition task with instanciated children. If
            # specializations have been specified on this composition, the
            # return task will be of the most specialized model that matches the
            # selection. See #specialize for more information.
            #
            # The :selection argument, if set, specifies explicit selections for
            # the composition's children. In its generality, the argument is a
            # hash which maps a child selector to a selected model.
            #
            # The selected model can be:
            # * a task, device driver or interface model
            # * a device name
            # * a task name as given to Engine#add
            #
            # In any case, the selected model must be compatible with the
            # child's definition and the additional constraints that have been
            # specified on it (see #constrain).
            #
            # The child selector can be (by order of precedence)
            # * a child name
            # * a child_name.child_of_child_name construct. In that case, the
            #   engine will search for a composition that can be used in place
            #   of +child_name+, and has a +child_name_of_child+ child that
            #   matches the selection.
            # * a child model or model name, in which case it will match the
            #   children of +self+ whose definition matches the given model.
            #
            def instanciate(engine, arguments = Hash.new)
                arguments, task_arguments = Model.filter_instanciation_arguments(arguments)
                user_selection = arguments[:selection]

                # First of all, add the task for +self+
                engine.plan.add(self_task = new(task_arguments))
                self_task.robot = engine.robot

                # Apply the selection to our children
                selected_models = filter_selection(engine, user_selection)

                # Find the specializations that apply
                candidates = find_specializations(engine, selected_models)

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

                    role = [child_name].to_set

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

        # Namespace for all defined composition models
        module Compositions
            def self.each
                constants.each do |name|
                    value = const_get(name)
                    yield(value) if value < RobyPlugin::Composition
                end
            end
        end

        # Compositions, i.e. grouping of components and/or other compositions
        # that perform a given function.
        #
        # Compositions are used to regroup components and/or other compositions
        # in functional groups.
        class Composition < Component
            extend CompositionModel

            terminates

            inherited_enumerable(:child, :children, :map => true) { Hash.new }
            inherited_enumerable(:child_constraint, :child_constraints, :map => true) { Hash.new { |h, k| h[k] = Array.new } }
            inherited_enumerable(:default_specialization, :default_specializations, :map => true) { Hash.new }

            # The set of connections specified by the user for this composition
            inherited_enumerable(:explicit_connection, :explicit_connections) { Hash.new { |h, k| h[k] = Hash.new } }
            # The set of connections automatically generated by
            # compute_autoconnection
            inherited_enumerable(:automatic_connection, :automatic_connections)

            # Outputs exported from this composition
            inherited_enumerable(:output, :outputs, :map => true)  { Hash.new }
            # Inputs imported from this composition
            inherited_enumerable(:input, :inputs, :map => true)  { Hash.new }

            def executable?(with_setup = false) # :nodoc:
                each_child do |child_task, _|
                    if child_task.kind_of?(Component) && !child_task.executable?(with_setup)
                        return false
                    end
                end
                super
            end

            # Returns the actual port that is currently used to provide data to
            # an exported output, or returns nil if there is currently none.
            #
            # This is used to discover which actual component is currently
            # providing a port on the composition. In other words, when one does
            #
            #   composition 'Test' do
            #       src = add Source
            #       export src.output
            #   end
            #
            # then, once the composition is instanciated,
            # test_task.output_port('output') will return src_task.output where
            # src_task is the actual component used for the Source child. If, at
            # the time of the call, no such component is present, then
            # output_port will return nil.
            #
            # See also #input_port
            def output_port(name)
                real_task, real_port = resolve_output_port(name)
                real_task.output_port(real_port)
            end

            # Helper method for #output_port and #resolve_port
            def resolve_output_port(name) # :nodoc:
                if !(port = model.output_port(name))
                    raise ArgumentError, "no output port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Returns the actual port that is currently used to get data from
            # an exported input, or returns nil if there is currently none.
            #
            # See #output_port for details.
            def input_port(name)
                real_task, real_port = resolve_input_port(name)
                real_task.input_port(real_port)
            end

            # Helper method for #output_port and #resolve_port
            def resolve_input_port(name) # :nodoc:
                if !(port = model.input_port(name.to_str))
                    raise ArgumentError, "no input port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Internal implementation of #output_port and #input_port
            def resolve_port(exported_port) # :nodoc:
                role = exported_port.child.child_name
                task, _ = each_child.find { |task, options| options[:roles].include?(role) }
                if !task
                    return
                end

                port_name = exported_port.port_name
                if task.kind_of?(Composition)
                    if exported_port.kind_of?(CompositionChildOutputPort)
                        return task.resolve_output_port(port_name)
                    else
                        return task.resolve_input_port(port_name)
                    end
                else
                    return task, port_name
                end
            end

            def actual_connections
                result = Array.new
                model.each_output do |_, exported_output|
                    real_port = resolve_port(exported_output)

                    real_port.task.each_parent_vertex(ActualDataFlow) do |source_task|
                        source_task[real_port.task, ActualDataFlow].each do |(source_port, sink_port), policy|
                            if sink_port == exported_port.port_name
                                result << [source_task, source_port, real_port.task, sink_port, policy]
                            end
                        end
                    end
                end

                model.each_input do |_, exported_input|
                    real_port = resolve_port(exported_input)
                    real_port.task.each_child_vertex(ActualDataFlow) do |sink_task|
                        real_port.task[sink_task, ActualDataFlow].each do |(source_port, sink_port), policy|
                            if source_port == exported_port.port_name
                                result << [real_port.task, source_port, sink_task, sink_port, policy]
                            end
                        end
                    end
                end
                result
            end

            # Helper for #added_child_object and #removing_child_object
            def dataflow_change_handler(child, mappings) # :nodoc:
                if child.kind_of?(TaskContext)
                    Flows::DataFlow.modified_tasks << child
                elsif child_object?(child, Roby::TaskStructure::Dependency)
                    mappings ||= self[child, Flows::DataFlow]
                    mappings.each_key do |source_port, sink_port|
                        real_task, _ = resolve_input_port(source_port)
                        if real_task && !real_task.transaction_proxy? # can be nil if the child has been removed
                            Flows::DataFlow.modified_tasks << real_task
                        end
                    end

                else
                    mappings ||= self[child, Flows::DataFlow]
                    mappings.each_key do |source_port, sink_port|
                        real_task, _ = resolve_output_port(source_port)
                        if real_task && !real_task.transaction_proxy? # can be nil if the child has been removed
                            Flows::DataFlow.modified_tasks << real_task
                        end
                    end
                end
            end

            # Called when a new child is added to this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def added_child_object(child, relations, mappings)
                super

                if relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, mappings)
                end
            end

            # Called when a child is removed from this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def removing_child_object(child, relations)
                super

                if relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, nil)
                end
            end

        end
    end
end

