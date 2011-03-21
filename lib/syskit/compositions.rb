module Orocos
    module RobyPlugin
        # Used by Composition to define its children. Values returned by
        # Composition#find_child(name) are instances of that class.
        class CompositionChildDefinition
            # The set of models that this child should fullfill. It is a
            # ValueSet which contains at most one Component model and any number
            # of data service models 
            attr_accessor :models
            attr_accessor :dependency_options
            attr_accessor :port_mappings

            attr_reader :using_spec
            attr_reader :arguments

            def initialize(models = ValueSet.new, dependency_options = Hash.new)
                @models = models
                @dependency_options = dependency_options
                @using_spec = Hash.new
                @port_mappings = Hash.new
                @arguments = Hash.new
            end

            def initialize_copy(old)
                @models = old.models.dup
                @dependency_options = old.dependency_options.dup
                @using_spec = old.using_spec.dup
                @port_mappings = old.port_mappings.dup
            end

            # Return true if this child provides all of the required models
            def fullfills?(required_models)
                if !required_models.respond_to?(:each)
                    required_models = [required_models]
                end
                required_models.all? do |req_m|
                    models.any? { |m| m.fullfills?(req_m) }
                end
            end

            # Adds specific arguments that should be passed to the child at
            # instanciation time
            #
            # This can be used to require a specific child configuration
            def with_arguments(arguments)
                @arguments = @arguments.merge(arguments)
            end

            # If this child is a composition, narrow its model based on the
            # provided selection specification.
            #
            # If the selection is enough to narrow down the model, return the
            # new model. Otherwise, return nil
            def use(*spec)
                spec = RobyPlugin.validate_using_spec(*spec)

                # Check that this child is a composition. Note that we have the
                # guarantee that there is at most one subclass of Composition in
                # models, as it is not allowed to have multiple classes in there
                composition_model = models.find { |m| m < Composition }
                if !composition_model
                    raise ArgumentError, "#use can be called only on children that are compositions"
                end

                SystemModel.debug do
                    SystemModel.debug "narrowing #{composition_model.short_name}"
                    spec_txt = spec.map do |name, models|
                        if name
                            "#{name} => #{models}"
                        else
                            "default selection: #{models.map(&:to_s).join(", ")}"
                        end
                    end
                    SystemModel.log_array :debug, "  on ", "     ", spec_txt
                    break
                end

                # Now update the spec and check if we can narrow down the model
                @using_spec = using_spec.merge(spec)
                candidates = composition_model.narrow(using_spec)
                if candidates.size == 1
                    new_model = candidates.find { true }
                    models.delete(composition_model)
                    models << new_model
                    SystemModel.debug do
                        SystemModel.debug "  found #{new_model.short_name}"
                        break
                    end
                    new_model
                else
                    SystemModel.debug "  cannot narrow it further"
                    nil
                end
            end
        end

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
        # CompositionModel#[] also returns instances from that class.
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
                composition.find_child(child_name).models
            end

            # If this child is itself a composition model, give more information
            # as to what specialization should be picked
            #
            # See CompositionChildDefinition#use
            def use(*spec)
                composition.find_child(child_name).use(*spec)
            end

            # Checks if this child fullfills the given model
            def fullfills?(model)
                composition.find_child(child_name).fullfills?(model)
            end

            # Specifies arguments that should be given to the child at
            # instanciation time
            #
            # See CompositionChildDefinition#with_arguments
            def with_arguments(spec)
                composition.find_child(child_name).with_arguments(spec)
            end

            # Returns a CompositionChildPort instance if +name+ is a valid port
            # name
            def method_missing(name, *args) # :nodoc:
                if args.empty?
                    name = name.to_s
                    composition.find_child(child_name).models.each do |child_model|
                        if port = child_model.find_output_port(name)
                            return CompositionChildOutputPort.new(self, port, name)
                        elsif port = child_model.find_input_port(name)
                            return CompositionChildInputPort.new(self, port, name)
                        end
                    end
                end

                raise NoMethodError, "in composition #{composition.short_name}: child #{child_name} of type #{composition.find_child(child_name).models.map(&:short_name).join(", ")} has no port named #{name}", caller(1)
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
            attr_accessor :name

            # Returns the true name for the port, i.e. the name of the port on
            # the child
            def actual_name; port.name end

            # THe port's type object
            def type; port.type end
            # The port's type name
            def type_name; port.type_name end

            # Declare that this port should be ignored in the automatic
            # connection computation
            def ignore
                child.composition.autoconnect_ignores << [child.child_name, name]
            end

            def initialize(child, port, port_name)
                @child = child
                @port  = port
                @name = port_name
            end

            def ==(other) # :nodoc:
                other.kind_of?(CompositionChildPort) && other.child == child &&
                    other.port == port &&
                    other.name == name
            end
        end

        # Specialization of CompositionChildPort for output ports
        class CompositionChildOutputPort < CompositionChildPort; end
        # Specialization of CompositionChildPort for input ports
        class CompositionChildInputPort  < CompositionChildPort; end

        # Additional methods that are mixed in composition specialization
        # models. I.e. composition models created by CompositionModel#specialize
        module CompositionSpecializationModel
            def is_specialization?; true end

            # The root composition model in the specialization chain
            attr_accessor :root_model
            # The set of definition blocks that have been applied on +self+ in
            # the process of specializing +root_model+
            attribute(:definition_blocks) { Array.new }

            # Returns the model name
            #
            # This is formatted as
            # root_model/child_name.is_a?(specialized_list),other_child.is_a?(...)
            def name
                specializations = self.specialized_children.map do |child_name, child_models|
                    "#{child_name}.is_a?(#{child_models.map(&:short_name).join(",")})"
                end

                "#{root_model.short_name}/#{specializations}"
            end

            # Applies the specialization block +block+ on +self+. If +recursive+
            # is true, also applies it on the children of this particular
            # specialization
            #
            # Whenever a new specialization block is applied on an existing
            # specialization, calling this method with recursive = true ensures
            # that the block is applied on all specialization models that should
            # have it applied
            def apply_specialization_block(block, recursive = true)
                if !definition_blocks.include?(block)
                    with_module(*RobyPlugin.constant_search_path, &block)
                    definition_blocks << block

                    if recursive
                        specializations.each do |subspec|
                            subspec.apply_specialization_block(block, false)
                        end
                    end
                end
            end

            # Returns the specialization spec that is a merge of the one of
            # +self+ with the specified one.
            def merge_specialization_spec(new_spec)
                specialized_children.merge(new_spec) do |child_name, models_a, models_b|
                    result = ValueSet.new
                    (models_a | models_b).each do |m|
                        if !result.any? { |result_m| result_m <= m }
                            result.delete_if { |result_m| m < result_m }
                            result << m
                        end
                    end
                    result
                end
            end
        end

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
            def new_submodel(name, system_model)
                klass = super()
                klass.name = "Orocos::RobyPlugin::Compositions::#{name.camelcase(:upper)}"
                klass.system_model = system_model
                klass
            end

            attribute(:autoconnect_ignores) { Set.new }

            # Returns the composition models that are parent to this one
            attribute(:parent_models) { ValueSet.new }

            ##
            # :attr: specializations
            #
            # The set of specializations defined at this level of the model
            # hierarchy, as an array of Specialization instances. See
            # #specialize for more details
            attribute(:specializations) { Hash.new }

            # The root composition model in the specialization hierarchy
            def root_model; self end

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            #
            # It is empty for composition models that are not specializations
            attribute(:specialized_children) { Hash.new }

            # Returns true if this composition model is a model created by
            # specializing another one on +child_name+ with +child_model+
            #
            # For instance:
            #
            #   composition 'Compo' do
            #       add Source
            #       add Sink
            #
            #       submodel = specialize Sink, Logger
            #
            #       submodel.specialized_on?('Sink', Logger) # => true
            #       submodel.specialized_on?('Sink', Test) # => false
            #       submodel.specialized_on?('Source', Logger) # => false
            #   end
            def specialized_on?(child_name, child_model)
                specialized_children.has_key?(child_name) &&
                    specialized_children[child_name].include?(child_model)
            end
            # Enumerates all the specializations of this model that are direct
            # children of it
            def each_direct_specialization(&block)
                if !block_given?
                    return enum_for(:each_direct_specialization)
                end

                specializations.each_value do |compo|
                    if compo.parent_models.include?(self)
                        yield(compo)
                    end
                end
            end

            # Enumerates all compositions that are specializations of this model
            def each_specialization(&block)
                specializations.each_value(&block)
            end

            #--
            # Documentation of the inherited_enumerable attributes defined on
            # Composition
            #++

            ##
            # :method: each_child
            # :call-seq:
            #   each_child { |child_name, child_models| }
            # 
            # Yields all children defined on this composition. +child_models+ is
            # a ValueSet of task classes (subclasses of Roby::Task) and/or task
            # tags (instances of Roby::TaskModelTag)

            ##
            # :method: find_child
            # :call-seq:
            #   find_child(child_name) -> child
            #
            # Returns the model requirements for the given child. The return
            # value is a ValueSet of task classes (subclasses of Roby::Task)
            # and/or task tags (instances of Roby::TaskModelTag)

            ##
            # :method: each_exported_input
            # :call-seq: each_exported_input { |export_name, port| }
            #
            # Yields the input ports that are exported by this composition.
            # +export_name+ is the name of the composition's port and +port+ the
            # CompositionChildPort object that represents the port that is being
            # exported.

            ##
            # :method: each_exported_output
            # :call-seq: each_exported_output { |export_name, port| }
            #
            # Yields the output ports that are exported by this composition.
            # +export_name+ is the name of the composition's port and +port+ the
            # CompositionChildPort object that represents the port that is being
            # exported.

            # Enumerates the input ports that are defined on this composition,
            # i.e.  the ports created by #export
            def each_input_port
                if block_given?
                    each_exported_input do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_input_port)
                end
            end

            # Returns the input port of this composition named +name+, or nil if
            # there are none
            def find_input_port(name); find_exported_input(name) end

            # Enumerates the output ports that are defined on this composition,
            # i.e.  the ports created by #export
            def each_output_port
                if block_given?
                    each_exported_output do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_output_port)
                end
            end

            # Returns the output port of this composition named +name+, or nil
            # if there are none
            def find_output_port(name); find_exported_output(name) end

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
            def add_child(name, child_model, dependency_options)
                name = name.to_str

                # We do NOT check for an already existing definition. The reason
                # is that specialization (among other) will add a default child,
                # that may be overriden by the composition's owner. Either to
                # set arguments, or to have a specialization over an aspect of a
                # data service use a more specific task model in the specialized
                # composition.
                #
                # Anyway, the remainder checks that the new definition is a
                # valid overloading of the previous one.

                child_task_model = child_model.find_all { |m| m < Component }
                if child_task_model.size > 1
                    raise ArgumentError, "more than one task model specified for #{name}"
                end
                child_task_model = child_task_model.first

                parent_model = find_child(name) || CompositionChildDefinition.new
                if child_task_model
                    parent_task_model = parent_model.models.find { |m| m < Component }
                    if parent_task_model && !(child_task_model <= parent_task_model)
                        raise ArgumentError, "trying to overload the child #{name} of #{short_name} of type #{parent_model.models.map(&:short_name).join(", ")} with #{child_model.map(&:short_name).join(", ")}"
                    end
                end

                # Delete from +parent_model+ everything that is already included
                # in +child_model+
                result = parent_model.dup
                result.models.delete_if do |parent_m|
                    replaced_by = child_model.find_all { |child_m| child_m < parent_m }
                    if !replaced_by.empty?
                        mappings = replaced_by.inject(Hash.new) do |mappings, m|
                            SystemModel.merge_port_mappings(mappings, m.port_mappings_for(parent_m))
                        end
                        result.port_mappings.clear
                        result.port_mappings.merge!(mappings)
                        parent_model.port_mappings.each do |from, to|
                            result.port_mappings[from] = mappings[to] || to
                        end
                    end
                end
                result.models |= child_model.to_value_set
                result.dependency_options = result.dependency_options.merge(dependency_options)

                SystemModel.debug do
                    SystemModel.debug "added child #{name} to #{short_name}"
                    SystemModel.debug "  with models #{result.models.map(&:short_name).join(", ")}"
                    if !parent_model.models.empty?
                        SystemModel.debug "  updated from #{parent_model.models.map(&:short_name).join(", ")}"
                    end
                    if !result.port_mappings.empty?
                        SystemModel.debug "  port mappings"
                        result.port_mappings.each do |from, to|
                            SystemModel.debug "    #{from} => #{to}"
                        end
                    end
                    break
                end
                children[name] = result
            end

            # Overloads an existing child with a new model and/or options
            #
            # This is 100% equivalent to
            #
            #   add model, (:as => name).merge(options)
            #
            # The only (important) difference is that it checks that +name+ is
            # indeed an existing child, and allows people that read the
            # composition model to understand the intent
            def overload(name, model, options = Hash.new)
                if !find_child(name)
                    raise ArgumentError, "#{name} is not an existing child of #{short_name}"
                end
                add(model, options.merge(:as => name))
            end

            # Add an element in this composition.
            #
            # This method adds a new element from the given component or data
            # service model. Raises ArgumentError if +model+ is of neither type.
            #
            # If an 'as' option is provided, this name will be used as the child
            # name. Otherwise, the basename of 'model' is used as the child
            # name. It will raise ArgumentError if the name is already used in this
            # composition.
            #
            # Returns the child definition as a CompositionChild instance. This
            # instance can also be accessed with Composition.[]
            #
            # For instance
            #   
            #   orientation_provider = data_service 'Orientation'
            #   # This child will be naned 'Orientation'
            #   composition.add orientation_provider
            #   # This child will be named 'imu'
            #   composition.add orientation_provider, :as => 'imu'
            #   composition['Orientation'] # => CompositionChild representing
            #                              # the first element
            #   composition['imu'] # => CompositionChild representing the second
            #                      # element
            #
            # == Subclassing
            #
            # If the composition model is a subclass of another composition
            # model, then +add+ can be used to override a child definition. In
            # if it the case, if +model+ is a component model, then it has to be
            # a subclass of any component model that has been used in the parent
            # composition. Otherwise, #add raises ArgumentError
            #
            # For instance,
            #
            #   raw_imu_readings = data_service "RawImuReadings"
            #   submodel = composition.new_submodel 'Foo'
            #   # This is fine as +raw_imu_readings+ and +orientation_provider+
            #   # can be combined. +submodel+ will require 'imu' to provide both
            #   # a RawImuReadings data service and a Orientation data service.
            #   submodel.add submodel, :as => 'imu' 
            #
            # Now, let's assume that 'imu' was declared as
            #
            #   composition.add XsensImu::Task, :as => 'imu'
            #
            # where XsensImu::Task is an actual component that drives IMUs from
            # the Xsens company. Then,
            #
            #   submodel.add DfkiImu::Task, :as => 'imu'
            #
            # would be invalid as the 'imu' child cannot be both an XsensImu and
            # DfkiImu task. In this case, you would need to define a common data
            # service that is provided by both components.
            def add(models, options = Hash.new)
                if !models.respond_to?(:each)
                    models = [models]
                end
                models = models.to_value_set

                wrong_type = models.find do |m|
                    !m.kind_of?(Roby::TaskModelTag) && !(m.kind_of?(Class) && m < Component)
                end
                if wrong_type
                    raise ArgumentError, "wrong model type #{wrong_type.class} for #{wrong_type}"
                end

                if models.size == 1
                    default_name = models.find { true }.snakename
                end
                options, dependency_options = Kernel.filter_options options,
                    :as => default_name

                if !options[:as]
                    raise ArgumentError, "you must provide an explicit name with the :as option"
                end

                add_child(options[:as], models, dependency_options)
                CompositionChild.new(self, options[:as])
            end

            # Returns this composition's main task
            #
            # The main task is the task that performs the composition's main
            # goal (if there is one). The composition will terminate
            # successfully whenever the main task finishes successfully.
            def main_task
                if @main_task then @main_task
                elsif superclass.respond_to?(:main_task)
                    superclass.main_task
                end
            end

            # Adds the given child, and marks it as the task that provides the
            # main composition's functionality.
            #
            # What is means in practice is that the composition will terminate
            # successfully when this child terminates successfully
            def add_main_task(models, options = Hash.new)
                if main_task
                    raise ArgumentError, "this composition already has a main task child"
                end
                @main_task = add(models, options)
            end

            # Requires the specified child to be of the given models. It is
            # mainly used in an abstract compostion definition to force the user
            # to select a specific child model.
            #
            # For instance, in
            #
            #   orientation_provider = data_service 'Orientation'
            #   composition.add orientation_provider, :as => 'imu'
            #   composition.constrain 'imu',
            #       [CompensatedSensors, RawSensors]
            #
            # Then the actual component selected for the composition's 'imu'
            # child would have to provide the Orientation data service *and*
            # either the CompensatedSensors and RawSensors (or both).
            #
            # If both can't be selected, use the :exclusive option, as:
            #
            #   composition.constrain 'imu',
            #       [CompensatedSensors, RawSensors],
            #       :exclusive => true
            #
            # This creates specializations for the allowed combinations. See
            # #specialize for more informations on specializations
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
                        specialize(child => model, :not => exclusions)
                    else
                        specialize(child => model)
                    end
                end

                child_constraints[child] << allowed_models
                filter_out_abstract_compositions

                abstract

                self
            end

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
            # FourWheelController data services.
            def specialize(options = Hash.new, &block)
                SystemModel.debug do
                    SystemModel.debug "trying to specialize #{short_name}"
                    for_txt = options.map do |name, models|
                        "#{name} => #{models}"
                    end
                    SystemModel.log_array(:debug, "  with ", "      ", for_txt)
                    SystemModel.debug ""
                    break
                end

                options, mappings = Kernel.filter_options options, :not => []
                if !options[:not].respond_to?(:to_ary)
                    options[:not] = [options[:not]]
                end

                # Normalize the user-provided specialization mapping
                new_spec = Hash.new
                mappings.each do |child, child_model|
                    if child.kind_of?(Module)
                        children = each_child.
                            find_all { |name, child_definition| child_definition.models.include?(child) }.
                            map { |name, _| name }

                        children.each do |child_name|
                            new_spec[child_name] = [child_model].to_value_set
                        end
                    elsif !child_model.respond_to?(:each)
                        new_spec[child.to_str] = [child_model].to_value_set
                    else
                        new_spec[child.to_str] = child_model.to_value_set
                    end
                end

                # ... and validate it
                verify_acceptable_specialization(new_spec)

                # Find out which of our specializations already apply for the
                # given mapping. Apply the specializations only on those
                matching_specializations = find_all_specializations(new_spec)
                matching_specializations << self

                # Remove the candidates that are filtered out by the :not option
                if !options[:not].empty?
                    matching_specializations.delete_if do |spec|
                        if child_specialization = spec.specialized_children[child_name]
                            if options[:not].any? { |model| child_specialization.fullfills?(model) }
                                true
                            end
                        end
                    end
                end

                create_specializations(matching_specializations, new_spec, &block)
            end

            # Creates specializations on +new_spec+ for each of the models
            # listed in +matching_specializations+. +matching_specializations+
            # is expected to be specializations of +self+ or +self+ itself.
            def create_specializations(matching_specializations, new_spec, &block)
                SystemModel.debug do
                    SystemModel.debug "creating new specialization of #{short_name}"
                    SystemModel.log_array(:debug, "  on  ", "      ", matching_specializations.map(&:short_name))
                    for_txt = new_spec.map do |name, models|
                        "#{name} => #{models.map(&:short_name).join(", ")}"
                    end
                    SystemModel.log_array(:debug, "  for ", "     ", for_txt)
                    SystemModel.debug ""
                    break
                end

                new_specializations = Hash.new
                matching_specializations.each do |specialization_model|
                    all_specializations = specialization_model.merge_specialization_spec(new_spec)

                    has_spec = specializations.keys.find { |m| m == all_specializations }
                    if has_spec && !specializations[all_specializations]
                        raise "blabla"
                    end

                    if spec = specializations[all_specializations]
                        Engine.debug "adding #{specialization_model.short_name} as parent of #{spec.short_name}"
                        # Make sure that +specialization_model+ knows about
                        # +spec+
                        spec.parent_models << specialization_model
                        specialization_model.register_specialization(spec)

                        # We already have a specialization with that signature.
                        #
                        # Apply the block recursively
                        spec.apply_specialization_block(block)
                        new_specializations[specialization_model] = spec
                    else
                        # Don't try to cross-specialize if the specialization is not
                        # valid.
                        valid = catch :invalid_selection do
                            specialization_model.verify_acceptable_specialization(new_spec, false)
                        end

                        Engine.debug "creating new specialization on #{specialization_model.short_name}"
                        # Create the specialization on the child. It will
                        # register it recursively on its own parents up to
                        # +self+
                        new_composition_model = specialization_model.
                            add_specialization(all_specializations, new_spec, &block)
                        new_specializations[specialization_model] = new_composition_model
                    end
                end

                # Now, update the parent list to reflect orthogonal
                # specializations
                matching_specializations.each do |composition_model|
                    specialized = new_specializations[composition_model]
                    composition_model.parent_models.each do |parent|
                        next if !matching_specializations.include?(parent)
                        specialized_parent = new_specializations[parent]
                        if specialized_parent != specialized
                            specialized.parent_models << specialized_parent
                            specialized_parent.register_specialization(specialized)
                        end
                    end
                end
            end

            def add_specialization(all_specializations, new_specializations, &block)
                # There's no composition with that spec. Create a new one
                child_composition = new_submodel('', system_model)
                child_composition.parent_models << self
                child_composition.extend CompositionSpecializationModel
                child_composition.specialized_children.merge!(all_specializations)
                child_composition.private_model
                child_composition.root_model = root_model
                new_specializations.each do |child_name, child_models|
                    child_composition.add child_models, :as => child_name
                end
                if block
                    child_composition.apply_specialization_block(block)
                end
                register_specialization(child_composition)
                child_composition
            end

            def register_specialization(specialization_model)
                has_spec = specializations.keys.find do |spec|
                    spec == specialization_model.specialized_children
                end

                if has_spec && !specializations[specialization_model.specialized_children]
                    raise "bloblo"
                end

                return if specializations[specialization_model.specialized_children]

                specializations[specialization_model.specialized_children] = specialization_model
                parent_models.each do |p_m|
                    p_m.register_specialization(specialization_model)
                end
            end

            # Verifies that the child selection in +new_spec+ is valid
            #
            # +new_spec+ has to be formatted as a mapping from child name to a
            # set of models that should be tested against the definition of the
            # child name, i.e.
            #
            #   child_name => child_models
            #--
            # +user_call+ is for internal use only. If set to false, instead of
            # raising an exception, it will throw :invalid_selection. This is
            # meant to avoid the (costly) creation of the exception message in
            # cases we don't have to report to the user.
            def verify_acceptable_specialization(new_spec, user_call = true)
                new_spec.each do |child_name, child_models|
                    if !has_child?(child_name)
                        raise ArgumentError, "there is no child called #{child_name} in #{short_name}"
                    end
                    child_models.each do |m|
                        verify_acceptable_child_specialization(child_name, m, user_call)
                    end
                end
            end

            # Checks if an instance of +child_model+ would be acceptable as
            # the +child_name+ child of +self+.
            #
            # Raises ArgumentError if the choice is not acceptable
            #--
            # +user_call+ is for internal use only. If set to false, instead of
            # raising an exception, it will throw :invalid_selection. This is
            # meant to avoid the (costly) creation of the exception message in
            # cases we don't have to report to the user.
            def verify_acceptable_child_specialization(child_name, child_model, user_call) # :nodoc:
                parent_models = find_child(child_name).models
                if parent_models.any? { |m| m <= child_model }
                    throw :invalid_selection if !user_call
                    raise ArgumentError, "#{child_model.short_name} does not specify a specialization of #{parent_models.map(&:short_name)}"
                end

                child_model.each_port do |port|
                    if conflict = parent_models.find { |m| !(child_model < m) && m.has_port?(port.name) }
                        throw :invalid_selection if !user_call
                        raise ArgumentError, "#{child_model.short_name} has a port called #{port.name}, which is already used by #{conflict.short_name}"
                    end
                end


                if child_model < Component && parent_class = parent_models.find { |m| m < Component }
                    if !(child_model < parent_class)
                        throw :invalid_selection if !user_call
                        raise ArgumentError, "#{child_model.short_name} is not a subclass of #{parent_class.short_name}, cannot specialize #{child_name} with it"
                    end
                end
                true
            end

            # Returns true if this composition model is a specialized version of
            # its superclass, and false otherwise
            def is_specialization?; false end

            # See CompositionSpecializationModel#specialized_on?
            def specialized_on?(child_name, child_model); false end

            # Returns the specialization specification which is a merge of
            # +new_spec+ with the specialization specification of +self+
            #
            # On non-specialized compositions, new_spec.dup is returned.
            def merge_specialization_spec(new_spec); new_spec.dup end
            
            def pretty_print(pp) # :nodoc:
                pp.text "#{name}:"
                data_services = each_data_service.to_a
                if !data_services.empty?
                    pp.nest(2) do
                        pp.breakable
                        pp.text "Data services:"
                        pp.nest(2) do
                            data_services.sort_by(&:first).
                                each do |name, ds|
                                    pp.breakable
                                    pp.text "#{name}: #{ds.model.name}"
                                end
                        end
                    end
                end
                specializations = each_direct_specialization.to_a
                if !specializations.empty?
                    pp.nest(2) do
                        pp.breakable
                        pp.text "Specializations:"
                        pretty_print_specializations(pp)
                    end
                end
            end

            def pretty_print_specializations(pp) # :nodoc:
                pp.nest(2) do
                    each_direct_specialization do |submodel|
                        pp.breakable
                        pp.text submodel.name
                        submodel.pretty_print_specializations(pp)
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
            #   default_specialization 'Control', SimpleController
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

            # Returns the composition models from model_set that are the most
            # specialized in the context the children listed in +children_names+
            #
            # I.e. if two models A and B have the same set of children, it will
            # remove A iff
            #
            # * all children of A that are listed in +children_names+ are also
            #   in B,
            # * for all children listed in +children_names+, the models required
            #   by B are either equivalent or specializations of the corresponding
            #   requirements in A
            # * there is at least one of those children that is specialized in
            #   +B+
            # 
            def find_most_specialized_compositions(model_set, children_names)
                return model_set if children_names.empty?

                result = model_set.dup

                # Remove +composition+ if there is a specialized model in
                # +result+
                result.delete_if do |composition|
                    result.any? do |other_composition|
                        next if composition == other_composition

                        children = (composition.all_children.keys & other_composition.all_children.keys) | children_names

                        is_specialized = false
                        children.each do |child_name|
                            comparison = system_model.compare_composition_child(
                                child_name, composition, other_composition)

                            this_child = composition.find_child(child_name)
                            other_child = other_composition.find_child(child_name)
                            if !comparison
                                is_specialized = false
                                break
                            elsif comparison == 1
                                is_specialized = true
                            end
                        end

                        is_specialized
                    end
                end

                # Now unconditionally remove specializations that have their
                # parents in +result+. Note that it is different from the
                # previous filtering as, unlike there, we don't look at specific
                # children
                result.delete_if do |composition|
                    next(false) if !composition.is_specialization?
                    result.any? do |model|
                        composition < model
                    end
                end
                
                result
            end

            def find_all_selected_specializations(selection)
                find_all_specializations(selection, true)
            end

            # Returns the set of specializations that are valid for the provided
            # mapping
            #
            # The mapping must be a mapping from child name to a set of models
            def find_all_specializations(selection, only_explicit_selection = false)
                candidates = ValueSet.new
                specializations.each do |mapping, composition|
                    next if candidates.include?(composition)

                    valid = mapping.all? do |child_name, child_models|
                        selected_models = selection[child_name]
                        if selected_models
                            # There is an explicit selection on +self+. Make
                            # sure that the specialization covers it
                            selected_models.all? do |selected_m|
                                selected_m.fullfills?(child_models)
                            end
                        else
                            !only_explicit_selection
                        end
                    end

                    if valid
                        candidates << composition
                    end
                end
                candidates
            end

            # Returns the most specialized compositions that are valid for the
            # provided mapping
            #
            # Unlike #find_all_specializations, it really only returns the most
            # specialized compositions, i.e. the leaves in the model graph
            def find_specializations(selected_models)
                Engine.debug do
                    Engine.debug "looking for specializations of #{short_name} on"
                    selected_models.each do |selector, m|
                        selector = selector.short_name if selector.respond_to?(:short_name)
                        Engine.debug "  #{selector} => #{m.map(&:short_name).join(", ")}"
                    end
                    break
                end

                raw_candidates = find_all_specializations(selected_models, false)
                candidates = raw_candidates.dup
                raw_candidates.each do |m|
                    candidates -= m.parent_models
                end

                Engine.debug do
                    Engine.debug "  initial results:"
                    raw_candidates.each do |m|
                        Engine.debug "    #{m.short_name} (leaf=#{candidates.include?(m)})"
                    end
                    break
                end


                all_filtered_results = Hash.new

                # First, filter on the facets. If the user provides a facet, it
                # means we should prefer the required specialization.
                selected_models.each do |child_name, selected_child_model|
                    selected_child_model = selected_child_model.first
                    next if !selected_child_model.respond_to?(:selected_facet)

                    selected_facet = selected_child_model.selected_facet

                    preferred_models = candidates.find_all do |composition_model|
                        composition_model.specialized_on?(child_name, selected_facet)
                    end

                    if !preferred_models.empty?
                        all_filtered_results[child_name] = preferred_models.to_value_set
                    end
                end

                if !all_filtered_results.empty?
                    filtered_out = all_filtered_results.values.inject(&:&)
                    if filtered_out.size == 1
                        return filtered_out.to_a
                    elsif filtered_out.empty?
                        facets = selected_models.dup
                        facets.delete_if do |name, child_model|
                            !child_model.first.respond_to?(:selected_facet)
                        end
                        raise IncompatibleFacetedSelection.new(self, facets, all_filtered_results), "inconsistent use of faceted selection"
                    end
                    candidates = filtered_out
                end

                # We now look at default specializations. Compositions that have
                # certain specializations are preferred over other.
                each_default_specialization do |child_name, default_child_model|
                    preferred_models = candidates.find_all do |composition_model|
                        composition_model.specialized_on?(child_name, default_child_model)
                    end

                    if !preferred_models.empty?
                        all_filtered_results[child_name] = preferred_models.to_value_set
                    end
                end

                # Check if the default specialization leads to something
                # meaningful
                filtered_out = all_filtered_results.values.inject(&:&)
                if filtered_out && !filtered_out.empty?
                    return filtered_out.to_a
                else
                    return candidates.to_a
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
                @autoconnect =
                    if names.empty? 
                        each_child.map { |n, _| n }
                    else names
                    end

                specializations.each_value do |spec|
                    spec.autoconnect(*names)
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
                if !force && automatic_connections
                    return self.automatic_connections
                end

                parent_connections = Hash.new
                if superclass.respond_to?(:compute_autoconnection)
                    parent_connections = superclass.compute_autoconnection(force)
                end

                if @autoconnect && !@autoconnect.empty?
                    if force || !automatic_connections
                        do_autoconnect(@autoconnect)
                    else
                        self.automatic_connections
                    end
                else
                    self.automatic_connections = map_connections(parent_connections)
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
            # It raises AmbiguousAutoConnection if there is more than one
            # candidate for an input port.
            def do_autoconnect(children_names)
                parent_autoconnections =
                    if (superclass < Composition)
                        map_connections(superclass.compute_autoconnection)
                    else Hash.new
                    end

                SystemModel.debug do
                    SystemModel.debug "computing autoconnections on #{short_name}"
                    SystemModel.debug "  parent connections:"
                    parent_autoconnections.each do |(child_out, child_in), mappings|
                        mappings.each do |(port_out, port_in), policy|
                            SystemModel.debug "    #{child_out}:#{port_out} => #{child_in}: #{port_in} [#{policy}]"
                        end
                    end
                    break
                end

                result = Hash.new { |h, k| h[k] = Hash.new }

                # First, gather per-type available inputs and outputs. Both
                # hashes are:
                #
                #   port_type_name => [[child_name, child_port_name], ...]
                child_inputs  = Hash.new { |h, k| h[k] = Array.new }
                child_outputs = Hash.new { |h, k| h[k] = Array.new }
                children_names.each do |name|
                    dependent_models = find_child(name).models
                    seen = Set.new
                    dependent_models.each do |sys|
                        sys.each_input_port do |in_port|
                            next if seen.include?(in_port.name)
                            next if exported_port?(in_port)
                            next if autoconnect_ignores.include?([name, in_port.name])

                            child_inputs[in_port.type_name] << [name, in_port.name]
                            seen << in_port.name
                        end

                        sys.each_output_port do |out_port|
                            next if seen.include?(out_port.name)
                            next if exported_port?(out_port)
                            next if autoconnect_ignores.include?([name, out_port.name])

                            child_outputs[out_port.type_name] << [name, out_port.name]
                            seen << out_port.name
                        end
                    end
                end


                existing_inbound_connections = Set.new
                (each_explicit_connection.to_a + parent_autoconnections.to_a).
                    each do |(_, child_in), mappings|
                        mappings.each_key do |_, port_in|
                            existing_inbound_connections << [child_in, port_in]
                        end
                    end

                # Now create the connections
                child_inputs.each do |typename, in_ports|
                    in_ports.each do |in_child_name, in_port_name|
                        # Ignore this port if there is an explicit inbound connection that involves it
                        next if existing_inbound_connections.include?([in_child_name, in_port_name])

                        # Now remove the potential connections to the same child
                        # We need to #dup as we modify the hash (delete_if just
                        # below)
                        out_ports = child_outputs[typename].dup
                        out_ports.delete_if do |out_child_name, out_port_name|
                            out_child_name == in_child_name
                        end
                        next if out_ports.empty?

                        # If it is ambiguous, check first if there is only one
                        # candidate that has the same name. If there is one,
                        # pick it. Otherwise, raise an exception
                        if out_ports.size > 1
                            # Check for identical port name
                            same_name = out_ports.find_all { |_, out_port_name| out_port_name == in_port_name }
                            if same_name.size == 1
                                out_ports = same_name
                            end

                            # Check for child name
                            includes_child_name = out_ports.find_all do |out_child_name, _|
                                in_port_name =~ /#{Regexp.quote(out_child_name)}/
                            end
                            if includes_child_name.size == 1
                                out_ports = includes_child_name
                            end
                        end

                        if out_ports.size > 1
                            error = AmbiguousAutoConnection.new(
                                self, typename,
                                [[in_child_name, in_port_name]],
                                out_ports)

                            out_port_names = out_ports.map { |child_name, port_name| "#{child_name}.#{port_name}" }
                            raise error, "multiple output candidates in #{name} for the input port #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
                        end

                        out_port = out_ports.first
                        result[[out_port[0], in_child_name]][ [out_port[1], in_port_name] ] = Hash.new
                    end
                end

                SystemModel.debug do
                    SystemModel.debug "automatic connection result in #{short_name}"
                    result.each do |(out_child, in_child), connections|
                        connections.each do |(out_port, in_port), policy|
                            SystemModel.debug "    #{out_child}:#{out_port} => #{in_child}:#{in_port} (#{policy})"
                        end
                    end
                    break
                end

                self.automatic_connections = result.merge(parent_autoconnections)
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

            def map_connections(connections)
                result = Hash.new
                connections.each do |(child_name_out, child_name_in), mappings|
                    child_out = find_child(child_name_out)
                    child_in  = find_child(child_name_in)

                    mapped = Hash.new
                    mappings.each do |(port_name_out, port_name_in), options|
                        port_name_out = (child_out.port_mappings[port_name_out] || port_name_out)
                        port_name_in  = (child_in.port_mappings[port_name_in]   || port_name_in)
                        mapped[[port_name_out, port_name_in]] = options
                    end
                    result[[child_name_out, child_name_in]] = mapped
                end
                result
            end

            def each_automatic_connection(&block)
                automatic_connections.each(&block)
            end

            def each_explicit_connection(&block)
                map_connections(each_unmapped_explicit_connection).each(&block)
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
                if self.find_port(name)
                    raise ArgumentError, "there is already a port named #{name} on #{short_name}"
                end

                case port
                when CompositionChildInputPort
                    exported_inputs[name] = port.dup
                    exported_inputs[name].name = name
                when CompositionChildOutputPort
                    exported_outputs[name] = port.dup
                    exported_outputs[name].name = name
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
                if exported = find_exported_output(port_model.name)
                    exported == port_model
                elsif exported = find_exported_input(port_model.name)
                    exported == port_model
                end
            end

            # Returns the port named 'name' in this composition
            #
            # See #export to create ports on a composition
            def find_port(name)
                name = name.to_str
                (find_output_port(name) || find_input_port(name))
            end

            # Returns the composition's output port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_output_port(name); find_exported_output(name.to_str) end

            # Returns the composition's input port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_input_port(name); find_exported_input(name.to_str) end

            # Returns true if +name+ is a valid dynamic input port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_input_port?(name); false end

            # Returns true if +name+ is a valid dynamic output port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_output_port?(name); false end

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
                    if !out_p.kind_of?(CompositionChildOutputPort)
                        raise ArgumentError, "#{out_p.name} is an input port of #{out_p.child.child_name}. The correct syntax is 'connect output => input'"
                    end
                    if !in_p.kind_of?(CompositionChildInputPort)
                        raise ArgumentError, "#{in_p.name} is an input port of #{in_p.child.child_name}. The correct syntax is 'connect output => input'"
                    end
                    unmapped_explicit_connections[[out_p.child.child_name, in_p.child.child_name]][ [out_p.name, in_p.name] ] = options
                end
            end

            def apply_port_mappings(connections, child_name, port_mappings) # :nodoc:
                connections.each do |(out_name, in_name), mappings|
                    mapped_connections = Hash.new

                    if out_name == child_name
                        mappings.delete_if do |(out_port, in_port), options|
                            if mapped_port = port_mappings[out_port]
                                mapped_connections[ [mapped_port, in_port] ] = options
                            end
                        end

                    elsif in_name == child_name
                        mappings.delete_if do |(out_port, in_port), options|
                            if mapped_port = port_mappings[in_port]
                                mapped_connections[ [out_port, mapped_port] ] = options
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
            def find_selected_compositions(child_name, selection) # :nodoc:
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
                candidates = system_model.each_composition.find_all do |composition_model|
                    if !selection_children.all? { |n| composition_model.all_children.has_key?(n) }
                        next
                    end

                    valid = catch :invalid_selection do
                        verify_acceptable_selection(child_name, composition_model, false)
                        true
                    end
                    next if !valid

                    valid = catch :invalid_selection do
                        composition_model.find_children_models_and_tasks(subselection, false)
                        true
                    end
                    valid
                end

                # Now select the most specialized models
                result = find_most_specialized_compositions(candidates, subselection.keys)
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
                        (child_model = model.find_child(child_name).models.to_a) &&
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

            def filter_ambiguities(candidates, selection)
                if candidates.size < 2 || !selection.has_key?(nil)
                    return candidates
                end

                result = candidates.find_all { |task| selection.include?(task) }
                if result.empty?
                    candidates
                else
                    result
                end
            end

            attr_reader :child_proxy_models

            # Creates a task model to proxy the services and/or task listed in
            # +models+
            def child_proxy_model(child_name, models)
                @child_proxy_models ||= Hash.new
                if m = child_proxy_models[child_name]
                    return m
                end

                if task_model = models.find { |t| t < Roby::Task }
                    model = task_model.specialize("proxy_" + models.map(&:short_name).join("_"))
                    model.abstract
                    model.class_eval do
                        @proxied_data_services = [task_model, *models]
                        def self.proxied_data_services
                            @proxied_data_services
                        end
                        def proxied_data_services
                            self.model.proxied_data_services
                        end
                    end
                else
                    model = Class.new(DataServiceProxy)
                end
                model.abstract
                name = "#{short_name}::#{child_name.camelcase(:upper)}Proxy"
                orogen_spec = RobyPlugin.create_orogen_interface(name.gsub(/[^\w]/, '_'))
                model.name        = name
                model.instance_variable_set(:@orogen_spec, orogen_spec)
                RobyPlugin.merge_orogen_interfaces(model.orogen_spec, models.map(&:orogen_spec))
                models.each do |m|
                    if m.kind_of?(DataServiceModel)
                        model.data_service m
                    end
                end
                child_proxy_models[child_name] = model
            end

            def compute_service_selection(child_name, task_model, required_services, user_call)
                result = Hash.new
                required_services.each do |required|
                    next if !required.kind_of?(DataServiceModel)
                    candidate_services =
                        task_model.find_all_services_from_type(required)

                    if task_model.respond_to?(:selected_facet)
                        subselection = task_model.selected_facet
                        candidate_services.delete_if { |m| !m.fullfills?(subselection) }
                    end

                    if candidate_services.size > 1
                        throw :invalid_selection if !user_call
                        raise AmbiguousServiceMapping.new(self, child_name, task_model, required, candidate_services),
                            "multiple services fullfill #{required.name} on #{task_model.name}: #{candidate_services.join(", ")}"
                    elsif candidate_services.empty?
                        throw :invalid_selection if !user_call
                        raise NoMatchingService.new(self, child_name, task_model, required),
                            "there is no service of #{task_model.name} that provide #{required.name}, for the child #{child_name} of #{self.name}"
                    end
                    result[required] = candidate_services.first
                end
                result
            end

            # Class returned by #find_selected_model_and_task to represent the
            # actual selection done a child
            class SelectedChild
                attr_accessor :is_explicit
                attr_accessor :selected_services
                attr_accessor :child_model
                attr_accessor :child_task
                attr_accessor :arguments
                attr_accessor :using_spec
                attr_accessor :port_mappings

                def initialize
                    @is_explicit = false
                    @selected_services = Hash.new
                    @child_model = nil
                    @child_task = nil
                    @arguments = Hash.new
                    @using_spec = Hash.new
                    @port_mappings = Hash.new
                end
            end
            
            # call-seq:
            #   find_selected_model_and_task(child_name, selection) -> is_default, selected_service, child_model, child_task
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
            #   given to a task instance in Engine#add. Otherwise, it can eithe
            #   be a task model (as a class object) or a task instance (as a
            #   Component instance).
            #
            def find_selected_model_and_task(child_name, selection, user_call = true) # :nodoc:
                required_model = find_child(child_name).models

                result = SelectedChild.new

                # First, simply check for the child's name
                if selected_object = selection[child_name]
                    result.is_explicit = true
                end

                # Now, check that if there is an explicit selection for a
                # child's child (i.e. starting with child_name.). In that
                # case, search for a matching composition
                if !selected_object
                    matching_compositions = find_selected_compositions(child_name, selection)
                    matching_compositions = filter_ambiguities(matching_compositions, selection)
                    if matching_compositions.size > 1
                        selection = selection.dup
                        selection.delete_if { |name, model| name !~ /^#{Regexp.quote("#{child_name}.")}/ }
                        throw :invalid_selection if !user_call
                        raise AmbiguousIndirectCompositionSelection.new(self, child_name, selection, matching_compositions),
                            "the following compositions match for #{child_name}: #{matching_compositions.map(&:to_s).join(", ")}"
                    end
                    if selected_object = matching_compositions.first
                        result.is_explicit = true
                    end
                end

                # Second, look into the child model
                if !selected_object
                    # Search for candidates in the user selection, from the
                    # child models
                    candidates = required_model.map do |m|
                        selection[m] || selection[m.name]
                    end.flatten.compact

                    # Search for candidates in the user selection, without the
                    # child models (i.e. the "default part" of the user
                    # selection)
                    if candidates.empty? && selection[nil]
                        candidates = selection[nil].find_all { |default_models| default_models.fullfills?(required_model) }
                    end

                    candidates = filter_ambiguities(candidates, selection)
                    if candidates.size > 1
                        throw :invalid_selection if !user_call
                        raise AmbiguousExplicitSelection.new(self, child_name, candidates), "there are multiple selections applying to #{child_name}: #{candidates.map(&:to_s).join(", ")}"
                    end

                    if selected_object = candidates.first
                        result.is_explicit = true
                    end
                end

                if !selected_object
                    # We don't have a selection, but the child model cannot be
                    # directly translated into a task model
                    if required_model.size > 1
                        required_model = [child_proxy_model(child_name, required_model)]
                    end

                    # no explicit selection, just add the default one
                    selected_object = required_model.first
                end

                if selected_object.kind_of?(InstanciatedComponent)
                    result.child_model = selected_object.model
                    result.using_spec  = selected_object.using_spec
                    result.arguments   = selected_object.arguments
                
                elsif selected_object.kind_of?(InstanciatedDataService)
                    if !selected_object.provided_service_model
                        raise InternalError, "#{selected_object} has no provided service model"
                    end
                    required_model.each do |required|
                        result.selected_services[required] = selected_object.provided_service_model
                    end
                    result.child_task       = selected_object.task
                    result.child_model      = child_task.model
                elsif selected_object.kind_of?(ProvidedDataService)
                    required_model.each do |required|
                        result.selected_services[required] = selected_object
                    end
                    result.child_model      = selected_object.component_model
                elsif selected_object.kind_of?(DataServiceModel)
                    result.child_model = selected_object.task_model
                elsif selected_object.kind_of?(Component)
                    result.child_task  = selected_object # selected an instance explicitely
                    result.child_model = selected_object.model
                    result.selected_services = compute_service_selection(child_name, result.child_model, required_model, user_call)
                elsif selected_object < Component
                    result.child_model = selected_object
                    result.selected_services = compute_service_selection(child_name, result.child_model, required_model, user_call)
                else
                    throw :invalid_selection if !user_call
                    raise ArgumentError, "invalid selection #{selected_object}: expected a device name, a task instance or a model"
                end

                return result
            end

            # Verifies that +selected_model+ is an acceptable selection for
            # +child_name+ on +self+. Raises InvalidSelection if it is not the case,
            # and ArgumentError if the specified child is not a child of this
            # composition.
            #
            # See also #acceptable_selection?
            def verify_acceptable_selection(child_name, selected_model, user_call = true) # :nodoc:
                dependent_model = find_child(child_name)
                if !dependent_model
                    raise ArgumentError, "#{child_name} is not the name of a child of #{self}"
                end

                dependent_model = dependent_model.models
                if !selected_model.fullfills?(dependent_model)
                    throw :invalid_selection if !user_call
                    raise InvalidSelection.new(self, child_name, selected_model, dependent_model),
                        "cannot select #{selected_model} for #{child_name}: [#{selected_model}] is not a specialization of [#{dependent_model.map(&:short_name).join(", ")}]"
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

            # Computes the required models and task instances for each of the
            # composition's children. It returns two mappings for the form
            #
            #   child_name => [child_model, child_task, port_mappings]
            #
            # where +child_name+ is the name of the child, +child_model+ is the
            # actual selected model and +child_task+ the actual selected task.
            #
            # +child_task+ will be non-nil only if the user specifically
            # selected a task.
            #
            # The first returned mapping is the set of explicit selections (i.e.
            # selections that are specified by +selection+) and the second one
            # is the complete result for all the composition children.
            def find_children_models_and_tasks(selection, user_call = true) # :nodoc:
                explicit = Hash.new
                result   = Hash.new
                each_child do |child_name, child_definition|
                    required_model = child_definition.models
                    selected_child =
                        find_selected_model_and_task(child_name, selection, user_call)
                    verify_acceptable_selection(child_name, selected_child.child_model, user_call)

                    # If the model is a plain data service (i.e. not a task
                    # model), we must map this service to a service on the
                    # selected task
                    port_mappings = Hash.new
                    selected_child.selected_services.each do |expected, selected|
                        if expected.kind_of?(DataServiceModel) && existing_mappings = selected.port_mappings_for(expected)
                            port_mappings = SystemModel.merge_port_mappings(port_mappings, existing_mappings)
                        end
                    end

                    Engine.debug do
                        Engine.debug "  selected #{selected_child.child_task || selected_child.child_model.name} (#{port_mappings}) for #{child_name} (#{required_model.map(&:name).join(",")})"
                        Engine.debug "    using #{selected_child.using_spec}"
                        Engine.debug "    arguments #{selected_child.arguments}"
                        break
                    end

                    selected_child.port_mappings = port_mappings
                    if selected_child.is_explicit
                        explicit[child_name] = selected_child
                    end
                    result[child_name] = selected_child
                end

                return explicit, result
            end

            # Cached set of all the children definitions for this composition
            # model. This is updated by #update_all_children
            #
            # It can be used to limit the impact of using #find_child, which
            # requires a traversal of the model ancestry.
            def all_children(force_computation = false)
                if @all_children
                    return @all_children
                else
                    compute_all_children
                end
            end
            
            def compute_all_children
                result = Hash.new
                each_child do |name, model|
                    result[name] = model
                end
                result
            end

            # Updates the #all_children hash
            def update_all_children
                @all_children = self.compute_all_children
            end

            # Returns the set of specializations that match +using_spec+
            def narrow(using_spec)
                user_selection, _ = find_children_models_and_tasks(using_spec)

                spec = Hash.new
                user_selection.each { |name, selection| spec[name] = [selection.child_model] }
                find_specializations(spec)
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.use(XsensImu::Task))
            #
            def use(*spec)
                Engine.create_instanciated_component(nil, nil, self).use(*spec)
            end

            ##
            # :method: strict_specialization_selection?
            #
            # If true, any ambiguity in the selection of composition
            # specializations will lead to an error. If false, the common parent
            # of all the possible specializations will be instanciated. One can
            # note that it is less dangerous that it sounds, as this parent is
            # most likely abstract and will therefore be rejected later in the
            # system deployment process.
            #
            # However, don't set this to false unless you know what you are
            # doing
            attr_predicate :strict_specialization_selection, true

            # Instanciates a task for the required child
            def instanciate_child(engine, self_task, self_arguments, child_name, selected_child) # :nodoc:
                child_selection = nil
                missing_child_instanciation = catch(:missing_child_instanciation) do
                    child_selection = ComponentInstanceSpec.resolve_using_spec(find_child(child_name).using_spec) do |key, sel|
                        if sel.kind_of?(CompositionChild)
                            task = self_task.child_from_role(sel.child_name)
                            if !task
                                throw :missing_child_instanciation, true
                            end
                            task
                        else
                            sel
                        end
                    end
                    false
                end

                if missing_child_instanciation
                    return
                end

                child_selection.merge!(selected_child.using_spec)
                child_selection = engine.resolve_explicit_selections(child_selection)
                # From this level's arguments, only forward the
                # selections that have explicitely given for our
                # children
                self_arguments[:selection].each do |from, to|
                    if from.respond_to?(:to_str) && from =~ /^#{child_name}\./
                        child_selection[$`] = to
                    end
                end
                engine.add_default_selections(child_selection)

                Engine.debug { "instanciating model #{selected_child.child_model.short_name} for child #{child_name}" }
                child_task = selected_child.child_model.instanciate(engine, :selection => child_selection)

                child_arguments = find_child(child_name).arguments.dup
                child_arguments.merge!(selected_child.arguments)
                child_arguments.each do |key, value|
                    if value.respond_to?(:resolve)
                        child_task.arguments[key] = value.resolve(self)
                    else
                        child_task.arguments[key] = value
                    end
                end

                child_task
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
            # * a task model, a data service model or a device model
            # * a device name as declared on Robot.devices
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
                arguments = Kernel.validate_options arguments, :as => nil, :selection => Hash.new
                user_selection = arguments[:selection]

                Engine.debug do
                    Engine.debug "instanciating #{name} with"
                    user_selection.each do |from, to|
                        from =
                            if from.respond_to?(:short_name)
                                from.short_name
                            else from
                            end
                        to =
                            if to.respond_to?(:short_name)
                                to.short_name
                            else to
                            end
                        Engine.debug "   #{from} => #{to}"
                    end
                    break
                end

                # Apply the selection to our children
                user_selection, selected_models = find_children_models_and_tasks(user_selection)

                # Find the specializations that apply
                find_specialization_spec = Hash.new
                user_selection.each { |name, sel| find_specialization_spec[name] = [sel.child_model] }
                candidates = find_specializations(find_specialization_spec)

                # Now, check if some of our specializations apply to
                # +selected_models+. If there is one, call #instanciate on it
                if Composition.strict_specialization_selection? && candidates.size > 1
                    raise AmbiguousSpecialization.new(self, user_selection, candidates)
                elsif !candidates.empty?
                    Engine.debug { "using specialization #{candidates[0].short_name} of #{short_name}" }
                    return candidates[0].instanciate(engine, arguments)
                end

                # First of all, add the task for +self+
                engine.plan.add(self_task = new)
                self_task.robot = engine.robot

                # The set of connections we must create on our children. This is
                # self.connections on which port mappings rules have been
                # applied
                connections = self.connections

                # Finally, instanciate the missing tasks and add them to our
                # children
                children_tasks = Hash.new
                while !selected_models.empty?
                    selected_models.delete_if do |child_name, selected_child|
                        if !(child_task = selected_child.child_task)
                            child_task = instanciate_child(engine, self_task, arguments, child_name, selected_child)
                        end

                        if !selected_child.port_mappings.empty?
                            Engine.debug do
                                Engine.debug "applying port mappings for #{child_name}"
                                selected_child.port_mappings.each do |from, to|
                                    Engine.debug "  #{from} => #{to}"
                                end
                                break
                            end
                            apply_port_mappings(connections, child_name, selected_child.port_mappings)
                        else
                            Engine.debug do
                                Engine.debug "no port mappings for #{child_name}"
                                break
                            end
                        end

                        role = [child_name].to_set
                        children_tasks[child_name] = child_task

                        dependent_models    = find_child(child_name).models.to_a
                        dependent_arguments = dependent_models.inject(Hash.new) do |result, m|
                            result.merge(m.meaningful_arguments(child_task.arguments))
                        end
                        if dependent_models.size == 1
                            dependent_models = dependent_models.first
                        end

                        dependency_options = find_child(child_name).dependency_options
                        dependency_options = { :success => [], :failure => [:stop], :model => [dependent_models, dependent_arguments], :roles => role }.
                            merge(dependency_options)

                        Engine.info do
                            Engine.info "adding dependency #{self_task}"
                            Engine.info "    => #{child_task}"
                            Engine.info "   options; #{dependency_options}"
                            break
                        end
                        self_task.depends_on(child_task, dependency_options)
                        if (main = main_task) && (main.child_name == child_name)
                            child_task.success_event.forward_to self_task.success_event
                        end
                        true # it has been processed, delete from selected_models
                    end
                end

                output_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_output do |output_name, port|
                    output_connections[ port.child.child_name ].
                        merge!([port.actual_name, output_name] => Hash.new)
                end
                output_connections.each do |child_name, mappings|
                    children_tasks[child_name].forward_ports(self_task, mappings)
                end

                input_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_input do |input_name, port|
                    input_connections[ port.child.child_name ].
                        merge!([input_name, port.actual_name] => Hash.new)
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
            # Yields the composition models that have been defined so far.
            def self.each
                constants.each do |name|
                    value = const_get(name)
                    yield(value) if value < RobyPlugin::Composition
                end
            end
        end

        # Alias for Compositions
        Cmp = Compositions

        # Compositions, i.e. grouping of components and/or other compositions
        # that perform a given function.
        #
        # Compositions are used to regroup components and/or other compositions
        # in functional groups.
        #
        # See the CompositionModel for class-level methods
        class Composition < Component
            extend CompositionModel

            @name = "Orocos::RobyPlugin::Composition"
            @strict_specialization_selection = true

            terminates

            inherited_enumerable(:child, :children, :map => true) { Hash.new }
            inherited_enumerable(:child_constraint, :child_constraints, :map => true) { Hash.new { |h, k| h[k] = Array.new } }
            inherited_enumerable(:default_specialization, :default_specializations, :map => true) { Hash.new }

            # The set of connections specified by the user for this composition
            inherited_enumerable(:unmapped_explicit_connection, :unmapped_explicit_connections) { Hash.new { |h, k| h[k] = Hash.new } }
            # The set of connections automatically generated by
            # compute_autoconnection
            #
            # #do_autoconnect computes all connections for the +self+ model, so
            # there is no need to use inherited_enumerable here
            class << self
                attr_accessor :automatic_connections
            end

            # Outputs exported from this composition
            inherited_enumerable(:exported_output, :exported_outputs, :map => true)  { Hash.new }
            # Inputs imported from this composition
            inherited_enumerable(:exported_input, :exported_inputs, :map => true)  { Hash.new }

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def fullfills?(models, args = Hash.new) # :nodoc:
                models = [models] if !models.respond_to?(:each)
                compo, normal = models.partition { |m| m <= Composition }
                if !super(normal, args)
                    return false
                elsif compo.empty?
                    return true
                else
                    (self.model <= compo.first) ||
                        compo.first.parent_model_of?(self.model)
                end
            end

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def self.fullfills?(models) # :nodoc:
                models = [models] if !models.respond_to?(:each)
                compo, normal = models.partition { |m| m <= Composition }
                if !super(normal)
                    return false
                elsif compo.empty?
                    return true
                else
                    (self <= compo.first) ||
                        compo.first.parent_model_of?(self)
                end
            end

            # Overriden from Roby::Task
            #
            # will return false if any of the children is not executable.
            def executable? # :nodoc:
                if !super
                    return false
                elsif @executable
                    return true
                end

                each_child do |child_task, _|
                    if child_task.kind_of?(TaskContext) && Roby.orocos_engine.dry_run?
                        if !child_task.orogen_task
                            return false
                        end
                    elsif !child_task.executable?
                        return false
                    end
                end
                return true
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
            # test_task.find_output_port('output') will return src_task.output where
            # src_task is the actual component used for the Source child. If, at
            # the time of the call, no such component is present, then
            # output_port will return nil.
            #
            # See also #input_port
            def find_output_port(name)
                real_task, real_port = resolve_output_port(name)
                real_task.find_output_port(real_port)
            end

            # Helper method for #output_port and #resolve_port
            def resolve_output_port(name) # :nodoc:
                if !(port = model.find_output_port(name))
                    raise ArgumentError, "no output port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Returns the actual port that is currently used to get data from
            # an exported input, or returns nil if there is currently none.
            #
            # See #output_port for details.
            def find_input_port(name)
                real_task, real_port = resolve_input_port(name)
                real_task.find_input_port(real_port)
            end

            # Helper method for #output_port and #resolve_port
            #
            # It returns a component instance and a port name.
            def resolve_input_port(name) # :nodoc:
                if !(port = model.find_input_port(name.to_str))
                    raise ArgumentError, "no input port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Internal implementation of #output_port and #input_port
            #
            # It returns the [component instance, port name] pair which
            # describes the port which is connected to +exported_port+, where
            # +exported_port+ is a port of this composition.
            #
            # In other words, it returns the port that is used to produce data
            # for the exported port +exported_port+.
            def resolve_port(exported_port) # :nodoc:
                role = exported_port.child.child_name
                task = child_from_role(role, false)
                if !task
                    return
                end

                port_name = exported_port.actual_name
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

            # Helper for #added_child_object and #removing_child_object
            #
            # It adds the task to Flows::DataFlow.modified_tasks whenever the
            # DataFlow relations is changed in a way that could require changing
            # the underlying Orocos components connections.
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
            def added_child_object(child, relations, mappings) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, mappings)
                end
            end

            # Called when a child is removed from this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def removing_child_object(child, relations) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, nil)
                end
            end

            def self.method_missing(m, *args, &block)
                if args.empty?
                    name = m.to_s
                    if has_child?(name)
                        return CompositionChild.new(self, name)
                    end
                end
                super
            end
        end
    end
end

