module Orocos
    module RobyPlugin
        # Used by Composition to define its children. Values returned by
        # Composition#find_child(name) are instances of that class.
        class CompositionChildDefinition < InstanceRequirements
            # The set of models that this child should fullfill. It is a
            # ValueSet which contains at most one Component model and any number
            # of data service models 
            attr_accessor :dependency_options
            attr_accessor :port_mappings

            def initialize(models = ValueSet.new, dependency_options = Hash.new)
                super(models)
                @dependency_options = dependency_options
                @port_mappings = Hash.new
            end

            def initialize_copy(old)
                super
                @dependency_options = old.dependency_options.dup
                @port_mappings = old.port_mappings.dup
            end
        end

        # Exception raised when CompositionChild#method_missing is called to
        # resolve a port but the port name is ambiguous
        class AmbiguousChildPort < RuntimeError
            attr_reader :composition_child
            attr_reader :port_name
            attr_reader :candidates

            def initialize(composition_child, port_name, candidates)
                @composition_child, @port_name, @candidates =
                    composition_child, port_name, candidates
            end

            def pretty_print(pp)
                pp.text "#{port_name} is ambiguous on the child #{composition_child.child_name} of"
                pp.breakable
                composition_child.composition.pretty_print(pp)
                pp.breakable
                pp.text "Candidates:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |c|
                        pp.text c
                    end
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

            def to_s # :nodoc:
                "#<CompositionChild: #{child_name} #{composition}>"
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
                self
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
                self
            end

            # Specifies the configuration that should be used on the specified
            # child
            def use_conf(*conf)
                composition.find_child(child_name).use_conf(*conf)
                self
            end

            def each_input_port(&block)
                composition.find_child(child_name).models.each do |child_model|
                    child_model.each_input_port do |p|
                        yield(CompositionChildInputPort.new(self, p, p.name))
                    end
                end
            end

            def each_output_port(&block)
                composition.find_child(child_name).models.each do |child_model|
                    child_model.each_output_port do |p|
                        yield(CompositionChildOutputPort.new(self, p, p.name))
                    end
                end
            end

            # Returns a CompositionChildPort instance if +name+ is a valid port
            # name
            def method_missing(name, *args) # :nodoc:
                if args.empty?
                    name = name.to_s
                    candidates = []
                    composition.find_child(child_name).models.map do |child_model|
                        if output = child_model.find_output_port(name)
                            candidates << [child_model, output]
                        end
                        if input  = child_model.find_input_port(name)
                            candidates << [child_model, input]
                        end
                    end

                    if candidates.size > 1
                        candidates = candidates.map do |model, port|
                            "#{model.short_name}.#{port.name}"
                        end
                        raise AmbiguousChildPort.new(self, name, candidates), "#{name} is ambiguous on the child #{child_name} of #{composition.short_name}: #{candidates.join(", ")}"
                    elsif candidates.size == 1
                        port = candidates.first[1]
                        case port
                        when Orocos::Spec::InputPort, CompositionChildInputPort
                            return CompositionChildInputPort.new(self, port, name)
                        when Orocos::Spec::OutputPort, CompositionChildOutputPort
                            return CompositionChildOutputPort.new(self, port, name)
                        else
                            raise InternalError, "child port #{port} is neither a Spec::OutputPort or Spec::InputPort"
                        end
                    end
                end

                raise NoMethodError, "in composition #{composition.short_name}: child #{child_name} of type #{composition.find_child(child_name).models.map(&:short_name).join(", ")} has no port named #{name}", caller(1)
            end

            def ==(other) # :nodoc:
                other.class == self.class &&
                    other.composition == composition &&
                    other.child_name == child_name
            end

            def each_fullfilled_model(&block)
                composition.find_child(child_name).each_fullfilled_model(&block)
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
            # [CompositionChild] The child object this port is part of
            attr_reader :child
            # [Orocos::Spec::Port] The port object that describes the actual port
            attr_reader :port
            # [String] The actual port name. Can be different from port.name in
            # case of port exports (in compositions) and port aliasing
            attr_accessor :name

            # Returns the true name for the port, i.e. the name of the port on
            # the child
            def actual_name; port.name end

            # The port's type object, as a subclass of Typelib::Type
            def type; port.type end
            # [String] The port's type name
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
        
            # Return true if the underlying port multiplexes, i.e. if it is
            # an input port that is expected to have multiple inbound
            # connections
            def multiplexes?
               @port.multiplexes?
            end
        end

        # Specialization of CompositionChildPort for output ports
        class CompositionChildOutputPort < CompositionChildPort; end
        # Specialization of CompositionChildPort for input ports
        class CompositionChildInputPort  < CompositionChildPort
            def multiplexes?
                false
            end
        end

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
            def apply_specialization_block(block)
                if !definition_blocks.include?(block)
                    with_module(*RobyPlugin.constant_search_path, &block)
                    definition_blocks << block
                end
            end

            # Registers a new composition model that is a specialization of
            # +self+. The generated model is registered on the root model (not
            # this one)
            def instanciate_specialization(merged, list)
                applied_specializations.each do |s|
                    merged.merge(s)
                end
                list = list + applied_specializations.to_a
                root_model.instanciate_specialization(merged, list)
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

            # The set of configurations declared with #conf
            attr_reader :conf

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

            ##
            # :attr: instanciated_specializations
            attribute(:instanciated_specializations) { Hash.new }

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

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            attribute(:applied_specializations) { Set.new }

            # A set of blocks that are used to evaluate if two specializations
            # can be applied at the same time
            #
            # The block should take as input two Specialization instances and
            # return true if it is compatible and false otherwise
            attribute(:specialization_constraints) { Array.new }

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

            # Returns true if +self+ is a parent model of +child_model+
            def parent_model_of?(child_model)
                (child_model < self) ||
                    specializations.values.include?(child_model)
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
                dependency_options = Roby::TaskStructure::Dependency.validate_options(dependency_options)

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
                result.base_models.delete_if do |parent_m|
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
                result.add_models(child_model.to_value_set)
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

            # DEPRECATED. Use #add_main instead.
            def add_main_task(models, options = Hash.new) # :nodoc:
                add_main(models, options)
            end

            # Adds the given child, and marks it as the task that provides the
            # main composition's functionality.
            #
            # What is means in practice is that the composition will terminate
            # successfully when this child terminates successfully
            def add_main(models, options = Hash.new)
                if main_task
                    raise ArgumentError, "this composition already has a main task child"
                end
                @main_task = add(models, options)
            end

            class Specialization
                attr_reader :specialized_children
                attr_reader :specialization_blocks
                attr_reader :compatibilities
                attr_accessor :composition_model

                def initialize(spec = Hash.new, block = nil)
                    @specialized_children = spec
                    @specialization_blocks = Array.new
                    if block
                        @specialization_blocks << block
                    end
                    @compatibilities = Set.new
                end

                def initialize_copy(old)
                    @specialized_children = old.specialized_children.dup
                    @specialization_blocks = old.specialization_blocks.dup
                    @compatibilities = old.compatibilities.dup
                end

                def empty?
                    specialized_children.empty?
                end

                def compatible_with?(spec)
                    empty? || spec == self || compatibilities.include?(spec)
                end

                def find_specialization(child_name, model)
                    if selected_models = specialized_children[child_name]
                        if matches = selected_models.find_all { |m| m.fullfills?(model) }
                            if !matches.empty?
                                return matches
                            end
                        end
                    end
                end

                def has_specialization?(child_name, model)
                    if selected_models = specialized_children[child_name]
                        selected_models.any? { |m| m.fullfills?(model) }
                    end
                end

                def add(new_spec, new_blocks)
                    specialized_children.merge!(new_spec) do |child_name, models_a, models_b|
                        result = Set.new
                        (models_a | models_b).each do |m|
                            if !result.any? { |result_m| result_m <= m }
                                result.delete_if { |result_m| m < result_m }
                                result << m
                            end
                        end
                        result
                    end
                    if new_blocks.respond_to?(:to_ary)
                        specialization_blocks.concat(new_blocks)
                    elsif new_blocks
                        specialization_blocks << new_blocks
                    end
                end

                def merge(other_spec)
                    @compatibilities =
                        if empty?
                            other_spec.compatibilities.dup
                        else
                            compatibilities & other_spec.compatibilities.dup
                        end
                    @compatibilities << other_spec

                    add(other_spec.specialized_children, other_spec.specialization_blocks)
                    self
                end

                def weak_match?(selection)
                    has_selection = false
                    selection.each do |child_name, selected_child|
                        this_selection = specialized_children[child_name]
                        next if !this_selection

                        has_selection = true

                        does_match =
                            if selected_child.respond_to?(:fullfills?)
                                selected_child.fullfills?(this_selection)
                            else
                                selected_child.any? do |submodel|
                                    submodel.fullfills?(this_selection)
                                end
                            end

                        if !does_match
                            return false
                        end
                    end
                    return has_selection
                end

                def strong_match?(selection)
                    selection.all? do |child_name, selected_child|
                        if this_selection = specialized_children[child_name]
                            if selected_child.respond_to?(:fullfills?)
                                selected_child.fullfills?(this_selection)
                            else
                                selected_child.any? do |submodel|
                                    submodel.fullfills?(this_selection)
                                end
                            end
                        else
                            return false
                        end
                    end
                end
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
                            new_spec[child_name] = [child_model].to_set
                        end
                    elsif !child_model.respond_to?(:each)
                        new_spec[child.to_str] = [child_model].to_set
                    else
                        new_spec[child.to_str] = child_model.to_set
                    end
                end

                # validate it
                verify_acceptable_specialization(new_spec)

                # register it
                specialization = (specializations[new_spec] ||= Specialization.new)
                specialization.add(new_spec, block)

                # and update compatibilities
                specializations.each_value do |spec|
                    next if spec == specialization
                    if compatible_specializations?(spec, specialization)
                        spec.compatibilities << specialization
                        specialization.compatibilities << spec
                    else
                        spec.compatibilities.delete(specialization)
                        specialization.compatibilities.delete(spec)
                    end
                end
            end

            def add_specialization_constraint(explicit = nil, &as_block)
                specialization_constraints << (explicit || as_block)
            end

            def compatible_specializations?(spec1, spec2)
                specialization_constraints.each do |validator|
                    if !validator[spec1, spec2]
                        return false
                    end
                end
                return true
            end

            def instanciate_all_possible_specializations
                all = partition_specializations(specializations.values)

                done_subsets = Set.new

                result = []
                all.each do |merged, set|
                    (1..set.size).each do |subset_size|
                        set.to_a.combination(subset_size) do |subset|
                            subset = subset.to_set
                            if !done_subsets.include?(subset)
                                merged = Specialization.new
                                subset.each { |spec| merged.merge(spec) }
                                result << instanciate_specialization(merged, subset)
                                done_subsets << subset
                            end
                        end
                    end
                end
                result
            end

            # Registers a new composition model that is a specialization of
            # +self+. +composite_spec+ is a Specialization object in which all
            # the required specializations have been merged and
            # +applied_specializations+ the list of the specializations,
            # separate.
            def instanciate_specialization(composite_spec, applied_specializations)
                if applied_specializations.empty?
                    return self
                elsif current_model = instanciated_specializations[composite_spec.specialized_children]
                    return current_model.composition_model
                end

                # There's no composition with that spec. Create a new one
                child_composition = new_submodel('', system_model)
                child_composition.parent_models << self
                child_composition.extend CompositionSpecializationModel
                child_composition.specialized_children.merge!(composite_spec.specialized_children)
                child_composition.applied_specializations = applied_specializations
                composite_spec.compatibilities.each do |single_spec|
                    child_composition.specializations[single_spec.specialized_children] ||= single_spec
                end
                child_composition.private_model
                child_composition.root_model = root_model
                composite_spec.specialized_children.each do |child_name, child_models|
                    child_composition.add child_models, :as => child_name
                end
                composite_spec.specialization_blocks.each do |block|
                    child_composition.apply_specialization_block(block)
                end
                composite_spec.composition_model = child_composition
                instanciated_specializations[composite_spec.specialized_children] = composite_spec

                child_composition
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
            
            def pretty_print(pp) # :nodoc:
                pp.text "#{root_model.name}:"

                specializations = specialized_children.to_a
                if !specializations.empty?
                    pp.text "Specialized on:"
                    pp.nest(2) do
                        specializations.each do |key, selected_models|
                            pp.breakable
                            pp.text "#{key}: "
                            pp.nest(2) do
                                pp.seplist(selected_models) do |m|
                                    m.pretty_print(pp)
                                end
                            end
                        end
                    end
                end
                
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
                raise NotImplementedError

                child = if child.respond_to?(:to_str)
                            child.to_str
                        else child.name.gsub(/.*::/, '')
                        end

                default_specializations[child] = child_model
            end

            def partition_specializations(specialization_set)
                if specialization_set.empty?
                    return []
                end

                candidates = []
                seed = specialization_set.first
                candidates << [seed.dup, [seed].to_set]
                specialization_set[1..-1].each do |spec_model|
                    new_candidates = []
                    candidates.each do |merged, all|
                        if merged.compatible_with?(spec_model)
                            merged.merge(spec_model)
                            all << spec_model
                        else
                            new_merged = spec_model.dup
                            new_all = all.find_all do |m|
                                if new_merged.compatible_with?(m)
                                    new_merged.merge(m)
                                    true
                                end
                            end
                            new_all << spec_model
                            new_candidates << [new_merged, new_all.to_set]
                        end
                    end
                    new_candidates.each do |new_merged, new_all|
                        if !candidates.any? { |_, all| all == new_all }
                            candidates << [new_merged, new_all]
                        end
                    end
                end
                candidates
            end

            # Find the sets of specializations that match +selection+
            #
            # The returned value is a set of [merged_specialization,
            # [atomic_specializations]], tuples. In each of these tuples,
            # 
            # * +merged_specialization+ is the Specialization instance
            #   representing the desired composite specialization
            # * +atomic_specializations+ is the set of single specializations
            #   that have been merged to obtain +merged_specialization+
            # 
            # Further disambiguation would, for instance, have to pick one of
            # these sets and call
            #
            #   instanciate_specialization(*candidates[selected_element])
            #
            # to get the corresponding composition model
            def find_matching_specializations(selection)
                if specializations.empty?
                    return []
                end

                Engine.debug do
                    Engine.debug "looking for specialization of #{short_name} on"
                    selection.each do |k, v|
                        Engine.debug "  #{k} => #{v}"
                    end
                    break
                end

                if model = instanciated_specializations[selection]
                    Engine.debug "  cached: #{model.composition_model.short_name}"
                    return model.composition_model
                end

                matching_specializations = specializations.values.find_all do |spec_model|
                    spec_model.weak_match?(selection)
                end

                Engine.debug do
                    Engine.debug "  #{matching_specializations.size} matching specializations found"
                    matching_specializations.each do |m|
                        Engine.debug "    #{m.specialized_children}"
                    end
                    break
                end

                if matching_specializations.empty?
                    return []
                end

                return partition_specializations(matching_specializations)
            end

            # Returns a single composition that can be used as a base model for
            # +selection+. Returns +self+ if the possible specializations are
            # ambiguous, or if no specializations apply. 
            def find_suitable_specialization(selection)
                all = find_matching_specializations(selection)
                if all.size != 1
                    return self
                else
                    return instanciate_specialization(*all.first)
                end
            end

            # Given a set of specialization sets, returns subset common to all
            # of the contained sets
            def find_common_specialization_subset(candidates)
                result = candidates[0][1].to_set
                candidates[1..-1].each do |merged, subset|
                    result &= subset.to_set
                end

                merged = result.inject(Specialization.new) do |merged, spec|
                    merged.merge(spec)
                end
                [merged, result]
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

                # First, gather per-type available inputs and outputs. Both
                # hashes are:
                #
                #   port_type_name => [[child_name, child_port_name], ...]
                child_inputs  = Array.new
                child_outputs = Array.new
                children_names.each do |name|
                    child = CompositionChild.new(self, name)
                    seen = Set.new
                    child.each_output_port do |out_port|
                        next if seen.include?(out_port.name)
                        next if exported_port?(out_port)
                        next if autoconnect_ignores.include?([name, out_port.name])
                        next if system_model.ignored_for_autoconnection?(out_port.port)

                        child_outputs << out_port
                        seen << out_port.name
                    end
                    child.each_input_port do |in_port|
                        next if seen.include?(in_port.name)
                        next if exported_port?(in_port)
                        next if autoconnect_ignores.include?([name, in_port.name])
                        next if system_model.ignored_for_autoconnection?(in_port.port)
                        child_inputs << in_port
                        seen << in_port.name
                    end
                end

                result = autoconnect_children(child_outputs, child_inputs, each_explicit_connection.to_a + parent_autoconnections.to_a)
                self.automatic_connections = result.merge(parent_autoconnections)
            end

            # Autoconnects the outputs listed in +child_outputs+ to the inputs
            # in child_inputs. +exclude_connections+ is a list of connections
            # whose input ports should be ignored in the autoconnection process.
            #
            # +child_outputs+ and +child_inputs+ are mappings of the form
            #
            #   type_name => [child_name, port_name]
            #
            # +exclude_connections+ is using the same format than the values
            # returned by each_explicit_connection (i.e. how connections are
            # stored in the DataFlow graph), namely a mapping of the form
            #
            #   (child_out_name, child_in_name) => mappings
            #
            # Where +mappings+ is
            #
            #   [port_out, port_in] => connection_policy
            #
            def autoconnect_children(child_output_ports, child_input_ports, exclude_connections)
                result = Hash.new { |h, k| h[k] = Hash.new }

                child_outputs = Hash.new { |h, k| h[k] = Array.new }
                child_output_ports.each do |p|
                    child_outputs[p.type_name] << [p.child.child_name, p.name]
                end
                child_inputs = Hash.new { |h, k| h[k] = Array.new }
                child_input_ports.each do |p|
                    child_inputs[p.type_name] << [p.child.child_name, p.name]
                end
                existing_inbound_connections = Set.new
                exclude_connections.each do |(_, child_in), mappings|
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
                result
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
                    child_inputs  = Array.new
                    child_outputs = Array.new

                    # Flags used to mark whether in_p resp. out_p have been
                    # explicitely given as ports or as child task. It is used to
                    # generate different error messages.
                    in_explicit, out_explicit = false

                    case out_p
                    when CompositionChildOutputPort
                        out_explicit = true
                        child_outputs << out_p
                    when CompositionChild
                        out_p.each_output_port do |p|
                            child_outputs << p
                        end
                    when CompositionChildInputPort
                        raise ArgumentError, "#{out_p.name} is an input port of #{out_p.child.child_name}. The correct syntax is 'connect output => input'"
                    else
                        raise ArgumentError, "#{out_p} is neither an input or output port. The correct syntax is 'connect output => input'"
                    end

                    case in_p
                    when CompositionChildInputPort
                        in_explicit = true
                        child_inputs << in_p
                    when CompositionChild
                        in_p.each_input_port do |p|
                            if !in_p
                                raise
                            end
                            child_inputs << p
                        end
                    when CompositionChildOutputPort
                        raise ArgumentError, "#{in_p.name} is an output port of #{in_p.child.child_name}. The correct syntax is 'connect output => input'"
                    else
                        raise ArgumentError, "#{in_p} is neither an input or output port. The correct syntax is 'connect output => input'"
                    end

                    result = autoconnect_children(child_outputs, child_inputs, each_explicit_connection.to_a)
                    # No connections found. This is an error, as the user
                    # probably expects #connect to create some, so raise the
                    # corresponding exception
                    if result.empty?
                        if in_explicit && out_explicit
                            raise ArgumentError, "cannot connect #{in_p.child.child_name}.#{in_p.name}[#{in_p.type_name}] to #{out_p.child.child_name}.#{out_p.name}[#{out_p.type_name}]: incompatible types"
                        elsif in_explicit
                            raise ArgumentError, "cannot find a match for #{in_p.child.child_name}.#{in_p.name}[#{in_p.type_name}] in #{out_p}"
                        elsif out_explicit
                            raise ArgumentError, "cannot find a match for #{out_p.child.child_name}.#{out_p.name}[#{out_p.type_name}] in #{in_p}"
                        else
                            raise ArgumentError, "no compatible ports found while connecting #{out_p} to #{in_p}"
                        end
                    end

                    unmapped_explicit_connections.merge!(result) do |k, v1, v2|
                        v1.merge!(v2)
                    end
                end
            end

            def apply_port_mappings_on_inputs(connections, port_mappings)
                mapped_connections = Hash.new
                connections.delete_if do |(out_port, in_port), options|
                    if mapped_port = port_mappings[in_port]
                        mapped_connections[ [out_port, mapped_port] ] = options
                    end
                end
                connections.merge!(mapped_connections)
            end

            def apply_port_mappings_on_outputs(connections, port_mappings)
                mapped_connections = Hash.new
                connections.delete_if do |(out_port, in_port), options|
                    if mapped_port = port_mappings[out_port]
                        mapped_connections[ [mapped_port, in_port] ] = options
                    end
                end
                connections.merge!(mapped_connections)
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

            attr_reader :child_proxy_models

            # Creates a task model to proxy the services and/or task listed in
            # +models+
            def child_proxy_model(child_name, models)
                @child_proxy_models ||= Hash.new
                if m = child_proxy_models[child_name]
                    return m
                end

                name = "#{name}::#{child_name.camelcase(:upper)}::PlaceholderTask"
                model = Orocos::RobyPlugin.placeholder_model_for(name, models)
                child_proxy_models[child_name] = model
            end

            # call-seq:
            #   find_selected_model_and_task(child_name, selection) -> SelectedChild
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
            def find_selected_model_and_task(child_name, context, user_call = true) # :nodoc:
                requirements   = InstanceRequirements.new(find_child(child_name).models)

                # Search for candidates in the user selection, from the
                # child models
                candidates = context.candidates_for(child_name, requirements)
                if candidates.size > 1
                    throw :invalid_selection if !user_call
                    raise AmbiguousExplicitSelection.new(self, child_name, candidates), "there are multiple selections applying to #{child_name}: #{candidates.map(&:to_s).join(", ")}"
                end

                if !candidates.empty?
                    result = InstanceSelection.from_object(candidates.first, requirements)
                    result.explicit = true
                else
                    result = InstanceSelection.new(find_child(child_name))
                end

                # Must compute the data service selection. We need to
                # finish cleanup all of that once and for all
                services = requirements.base_models.
                    find_all { |m| m.kind_of?(DataServiceModel) }
                result.select_services_for(services)

                return result

            rescue AmbiguousServiceSelection => e
                raise AmbiguousServiceMapping.new(
                    self, child_name, e.task_model, e.required_service, e.candidates), e.message, e.backtrace
            rescue NoMatchingService => e
                raise NoMatchingServiceForCompositionChild.new(
                    self, child_name, e.task_model, e.required_service), e.message, e.backtrace
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
            def find_children_models_and_tasks(context, user_call = true) # :nodoc:
                explicit = Hash.new
                result   = Hash.new
                each_child do |child_name, child_requirements|
                    selected_child =
                        find_selected_model_and_task(child_name, context, user_call)

                    # If the model is a plain data service (i.e. not a task
                    # model), we must map this service to a service on the
                    # selected task
                    port_mappings = Hash.new
                    selected_child.selected_services.each do |expected, selected|
                        if expected.kind_of?(DataServiceModel) && (existing_mappings = selected.port_mappings_for(expected))
                            port_mappings = SystemModel.merge_port_mappings(port_mappings, existing_mappings)
                        end
                    end

                    Engine.log_nest(2, :debug) do
                        Engine.debug "selected #{selected_child.selected_task || selected_child.requirements} (#{port_mappings}) for #{child_name} (#{child_requirements})"
                        Engine.log_nest(2) do
                            Engine.debug "services: #{selected_child.selected_services}"
                            Engine.debug "using"
                            Engine.log_pp(:debug, context.current_state)
                            Engine.debug "arguments #{selected_child.requirements.arguments}"
                        end
                    end

                    selected_child.port_mappings = port_mappings
                    if selected_child.explicit?
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
            def prepare
                @all_children = self.compute_all_children
            end

            # Returns the set of specializations that match the given dependency
            # injection context
            def narrow(context)
                user_selection, _ = find_children_models_and_tasks(context)

                spec = Hash.new
                user_selection.each { |name, selection| spec[name] = selection.requirements.models }
                find_suitable_specialization(spec)
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
            def instanciate_child(engine, context, self_task, child_name, selected_child) # :nodoc:
                # Make sure we can resolve all the children needed to
                # instanciate this level (if referred to by CompositionChild)
                requirements = selected_child.requirements
                selections = requirements.selections.map do |sel|
                    if sel.kind_of?(CompositionChild)
                        begin self_task.child_from_role(sel.child_name)
                        rescue ArgumentError
                            # The using spec of this child refers to another
                            # task's child, but that other child is not
                            # instanciated yet. Pass on, and get called
                            # later
                            return
                        end
                    else
                        sel
                    end
                end
                context.push(selections)

                Engine.debug { "instanciating model #{selected_child.requirements} for child #{child_name}" }

                child_arguments = selected_child.requirements.arguments
                child_arguments.each_key do |key|
		    value = child_arguments[key]
                    if value.respond_to?(:resolve)
                        child_arguments[key] = value.resolve(self)
                    end
                end

                child_task = selected_child.instanciate(engine, context, :task_arguments => child_arguments)
                child_task.required_host = find_child(child_name).required_host || self_task.required_host
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
            def instanciate(engine, context, arguments = Hash.new)
                arguments = Kernel.validate_options arguments, :as => nil, :task_arguments => Hash.new

                barrier = Hash.new
                selection = context.top.added_info
                each_child do |child_name, _|
                    if !selection.has_selection?(child_name)
                        barrier[child_name] = nil
                    end
                end

                Engine.debug do
                    Engine.debug "instanciating #{name} with"
                    Engine.log_nest(2) do
                        Roby.log_pp(context, Engine, :debug)
                    end
                    break
                end

                # Apply the selection to our children
                user_selection, selected_models =
                    context.save do
                        context.push(barrier)
                        find_children_models_and_tasks(context)
                    end

                # Find the specializations that apply
                find_specialization_spec = Hash.new
                user_selection.each { |name, sel| find_specialization_spec[name] = sel.requirements.models }
                candidates = find_matching_specializations(find_specialization_spec)
                if Composition.strict_specialization_selection? && candidates.size > 1
                    raise AmbiguousSpecialization.new(self, user_selection, candidates)
                elsif !candidates.empty?
                    specialized_model = find_common_specialization_subset(candidates)
                    specialized_model = instanciate_specialization(*specialized_model)
                    specialized_model = instanciate_specialization(*candidates.first)
                    if specialized_model != self
                        Engine.debug do
                            Engine.debug "using specialization #{specialized_model.short_name} of #{short_name}"
                            break
                        end
                        return specialized_model.instanciate(engine, context, arguments)
                    end
                end

                # First of all, add the task for +self+
                engine.plan.add(self_task = new(arguments[:task_arguments]))
                self_task.robot = engine.robot

                conf = if self_task.has_argument?(:conf)
                           self_task.conf(self_task.arguments[:conf])
                       else Hash.new
                       end

                # The set of connections we must create on our children. This is
                # self.connections on which port mappings rules have been
                # applied. Idem for exported inputs and outputs
                connections = self.connections
                exported_outputs = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_output do |output_name, port|
                    exported_outputs[ port.child.child_name ].
                        merge!([port.actual_name, output_name] => Hash.new)
                end
                exported_inputs = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_input do |input_name, port|
                    exported_inputs[ port.child.child_name ].
                        merge!([input_name, port.actual_name] => Hash.new)
                end

                # Finally, instanciate the missing tasks and add them to our
                # children
                children_tasks = Hash.new
                while !selected_models.empty?
                    current_size = selected_models.size
                    selected_models.delete_if do |child_name, selected_child|
                        if !(child_task = selected_child.selected_task)
                            # Get out of the selections the parts that are
                            # relevant for our child. We only pass on the
                            # <child_name>.blablabla form, everything else is
                            # removed

                            child_selection_context = context.dup
                            last = child_selection_context.pop

                            child_user_selection = Hash.new
                            last.added_info.explicit.each do |name, sel|
                                if name =~ /^#{child_name}\.(.*)$/
                                    child_user_selection[$1] = sel
                                end
                            end
                            child_selection_context.push(child_user_selection)
                            child_task = instanciate_child(engine, child_selection_context,
                                                           self_task, child_name, selected_child)
                            if !child_task
                                # Cannot instanciate yet, probably because the
                                # instantiation of this child depends on other
                                # children that are not yet instanciated
                                next(false)
                            end
                            if child_conf = conf[child_name]
                                child_task.arguments[:conf] ||= child_conf
                            end
                        end

                        if selected_child.port_mappings.empty?
                            Engine.debug { "no port mappings for #{child_name}" }
                        else
                            port_mappings = selected_child.port_mappings
                            Engine.debug do
                                Engine.debug "applying port mappings for #{child_name}"
                                port_mappings.each do |from, to|
                                    Engine.debug "  #{from} => #{to}"
                                end
                                Engine.debug "on"
                                connections.each do |(out_name, in_name), mappings|
                                    Engine.debug "  #{out_name} => #{in_name} (#{mappings})"
                                end
                                break
                            end
                            connections.each do |(out_name, in_name), mappings|
                                if out_name == child_name
                                    apply_port_mappings_on_outputs(mappings, port_mappings)
                                elsif in_name == child_name
                                    apply_port_mappings_on_inputs(mappings, port_mappings)
                                end
                            end
                            if exported_inputs.has_key?(child_name)
                                apply_port_mappings_on_inputs(exported_inputs[child_name], port_mappings)
                            end
                            if exported_outputs.has_key?(child_name)
                                apply_port_mappings_on_outputs(exported_outputs[child_name], port_mappings)
                            end

                            Engine.debug do
                                Engine.debug "result"
                                connections.each do |(out_name, in_name), mappings|
                                    Engine.debug "  #{out_name} => #{in_name} (#{mappings})"
                                end
                                break
                            end
                        end

                        role = [child_name].to_set
                        children_tasks[child_name] = child_task

                        dependent_models    = find_child(child_name).models.to_a
                        dependent_arguments = dependent_models.inject(Hash.new) do |result, m|
                            result.merge(m.meaningful_arguments(child_task.arguments))
                        end
                        if child_task.has_argument?(:conf)
                            dependent_arguments[:conf] = child_task.arguments[:conf]
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
                        self_task.child_selection[child_name] = selected_child
                        if (main = main_task) && (main.child_name == child_name)
                            child_task.each_event do |ev|
                                if !ev.terminal? && ev.symbol != :start && self_task.has_event?(ev.symbol)
                                    child_task.event(ev.symbol).forward_to self_task.event(ev.symbol)
                                end
                            end
                            child_task.success_event.forward_to self_task.success_event
                        end
                        true # it has been processed, delete from selected_models
                    end
                    if selected_models.size == current_size
                        raise InternalError, "cannot resolve #{child_name}"
                    end
                end

                exported_outputs.each do |child_name, mappings|
                    children_tasks[child_name].forward_ports(self_task, mappings)
                end
                exported_inputs.each do |child_name, mappings|
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

            def initialize(options = Hash.new)
                @child_selection = Hash.new
                super
            end

            # A name => SelectedChild mapping of the selection result during
            # #instanciate
            attr_reader :child_selection

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
            # Configurations defined on this composition model
            inherited_enumerable(:configuration, :configurations, :map => true)  { Hash.new }

            # Declares a composition configuration
            #
            # Composition configurations are named selections of configurations.
            #
            # For instance, if
            #
            #   conf 'narrow',
            #       'monitoring' => ['default', 'narrow_window'],
            #       'sonar' => ['default', 'narrow_window']
            #
            # is declared, and the composition is instanciated with
            #
            #   Cmp::SonarMonitoring.use_conf('narrow')
            #
            # Then the composition children called 'monitoring' and 'sonar' will
            # be both instanciated with ['default', 'narrow_window']
            def self.conf(name, mappings = Hash.new)
                configurations[name] = mappings
            end

            # Returns the configuration definition for the given
            # configuration(s)
            #
            # Note that unlike ConfigurationManager, only one configuration
            # can be selected (they cannot be overlaid on top of each other)
            #
            # The returned value is a mapping from child names to the
            # configurations that should be applied to them, i.e. for the
            # 'narrow' configuration used as an example in Composition.conf,
            #
            #   conf(['narrow'])
            #
            # would return
            #
            #   'monitoring' => ['default', 'narrow_window'],
            #   'sonar' => ['default', 'narrow_window']
            def conf(names)
                if names.size != 1
                    raise ArgumentError, "unlike with ConfigurationManager, only one  configuration can be selected on compositions"
                end

                result = Hash.new
                found_something = false
                model.each_configuration(names.first.to_s, false) do |values|
                    found_something = true
                    result = values.merge(result)
                end
                if !found_something
                    if names == ['default']
                        ConfigurationManager.info "required default configuration on composition #{task}, but #{task.model.short_name} has no registered default configurations"
                        return result
                    else
                        raise ArgumentError, "#{self} has no declared configuration called #{names.join(", ")}"
                    end
                end
                result
            end

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
                    if child_task.kind_of?(TaskContext)
                        if !child_task.orogen_task
                            return false
                        end
                    elsif child_task.kind_of?(Component)
                        if !child_task.executable?
                            return false
                        end
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
            rescue ArgumentError
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
            rescue ArgumentError
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

            def map_child_port(child_name, port_name)
                if mapped = model.find_child(child_name).port_mappings[port_name]
                    return mapped
                elsif mapped = child_selection[child_name].port_mappings[port_name]
                    return mapped
                else
                    port_name
                end
            end

            # Helper for #added_child_object and #removing_child_object
            #
            # It adds the task to Flows::DataFlow.modified_tasks whenever the
            # DataFlow relations is changed in a way that could require changing
            # the underlying Orocos components connections.
            def dataflow_change_handler(child, mappings) # :nodoc:
                return if !plan || !plan.real_plan.executable?

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

            def fullfills?(models, arguments = Hash.new)
                models = [*models].map do |other_model|
                    if other_model <= Composition
                        if !(other_model.applied_specializations - model.applied_specializations).empty?
                            return false
                        end
                        other_model.root_model
                    else
                        other_model
                    end
                end
                return super(models, arguments)
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

            # Proxy returned by the child_name_child handler
            #
            # This is used to perform port mapping if needed
            class CompositionChildInstance
                def initialize(composition_task, child_name, child_task)
                    @composition_task, @child_name, @child_task = composition_task, child_name, child_task
                end
                def as_plan
                    @child_task
                end

                def connect_ports(target_task, mappings)
                    mapped_connections = Hash.new
                    mappings.map do |(source, sink), policy|
                        source = find_output_port(source).name
                        mapped_connections[[source, sink]] = policy
                    end
                    @child_task.connect_ports(target_task, mapped_connections)
                end

                def disconnect_ports(target_task, mappings)
                    mappings = mappings.map do |source, sink|
                        source = find_output_port(source).name
                        [source, sink]
                    end
                    @child_task.disconnect_ports(target_task, mappings)
                end

                def find_input_port(port_name)
                    mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                    @child_task.find_input_port(mapped_port_name)
                end

                def find_output_port(port_name)
                    mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                    @child_task.find_output_port(mapped_port_name)
                end

                def method_missing(m, *args, &block)
                    if m.to_s =~ /^(\w+)_port$/
                        port_name = $1
                        mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                        if port = @child_task.find_input_port(mapped_port_name)
                            return port
                        elsif port = @child_task.find_output_port(mapped_port_name)
                            return port
                        else raise NoMethodError, "task #{@child_task}, child #{@child_name} of #{@composition_task}, has no port called #{port_name}"
                        end
                    end
                    @child_task.send(m, *args, &block)
                end
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block
                    if m.to_s =~ /^(\w+)_child$/
                        child_name = $1
                        # Verify that the child exists
                        child_task = child_from_role(child_name)
                        return CompositionChildInstance.new(self, child_name, child_task)
                    end
                end
                super
            end
        end
    end
end

