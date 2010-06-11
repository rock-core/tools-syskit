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

            def initialize(models = ValueSet.new, dependency_options = Hash.new)
                @models = models
                @dependency_options = dependency_options
            end

            def initialize_copy(old)
                @models = old.models.dup
                @dependency_options = old.dependency_options.dup
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

            # Returns a CompositionChildPort instance if +name+ is a valid port
            # name
            def method_missing(name, *args) # :nodoc:
                if args.empty?
                    composition.find_child(child_name).models.each do |child_model|
                        if port = child_model.output_port(name)
                            return CompositionChildOutputPort.new(self, port, name.to_str)
                        elsif port = child_model.input_port(name)
                            return CompositionChildInputPort.new(self, port, name.to_str)
                        end
                    end
                end

                raise NoMethodError, "child #{child_name}[#{composition.find_child(child_name).models.to_a.join(", ")}] of #{composition} has no port named #{name}", caller(1)
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

            # THe port's type object
            def type; port.type end
            # The port's type name
            def type_name; port.type_name end

            def initialize(child, port, port_name)
                @child = child
                @port  = port
                @port_name = port_name
            end

            def ==(other) # :nodoc:
                other.kind_of?(CompositionChildPort) && other.child == child &&
                    other.port == port &&
                    other.port_name == port_name
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

            # Returns a name to model_set mapping of the specializations that
            # have been applied to get to this model from its direct parent.
            #
            # I.e. if one does
            #
            #   first_specialization = composition.specialize 'child' => model
            #   second_specialization =
            #       first_specialization.specialize 'other_child' => other_model
            #
            # then first_specialization.self_specialization will return
            #
            #   { 'child' => #<ValueSet: model> }
            #
            # and second_specialization.self_specialization will return
            #
            #   { 'other_child' => #<ValueSet: other_model> }
            #
            # See all_specializations to get all the specializations that go
            # from the root composition to this composition
            def self_specialization
                result = Hash.new
                parent_model.specializations.find { |s| s.composition == self }.
                    specialized_children.each do |child_name, child_model|
                        result[child_name] = [child_model].to_value_set
                    end
                result
            end

            # Returns a name to model_set mapping of the specializations that
            # have been applied to get to this model from the root composition.
            #
            # I.e. if one does
            #
            #   first_specialization = composition.specialize 'child' => model
            #   second_specialization =
            #       first_specialization.specialize 'other_child' => other_model
            #
            # then first_specialization.self_specialization will return
            #
            #   { 'child' => #<ValueSet: model> }
            #
            # and second_specialization.self_specialization will return
            #
            #   { 'child' => #<ValueSet: model>,
            #   'other_child' => #<ValueSet: other_model> }
            #
            # See also self_specialization
            def all_specializations
                superclass = parent_model
                if superclass.is_specialization?
                    superclass.all_specializations.
                        merge(self_specialization) do |child_name, old_models, new_models|
                            old_models | new_models
                        end
                else
                    self_specialization
                end
            end

            # Returns the model name
            #
            # This is formatted as
            # root_model/child_name.is_a?(specialized_list),other_child.is_a?(...)
            def name
                specializations = all_specializations.map do |child_name, child_models|
                    "#{child_name}.is_a?(#{child_models.map(&:name).join(",")})"
                end

                root = ancestors.find { |k| k.kind_of?(Class) && !k.is_specialization? }
                "#{root.name}/#{specializations}"
            end

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
                parent = parent_model
                return if parent == Composition

                spec_model = parent.specializations.find { |s| s.composition == self }
                return if !spec_model

                spec_model.specialized_children[child_name] == child_model ||
                    parent.specialized_on?(child_name, child_model)
            end

            # Overloaded from CompositionModel
            def pretty_print_specializations(pp) # :nodoc:
                data_services = each_data_service.to_a
                parent = parent_model
                data_services.delete_if do |name, ds|
                    parent.find_data_service(name) == ds.model
                end

                if !data_services.empty?
                    pp.nest(2) do
                        pp.breakable
                        pp.text "Data Services:"
                        pp.nest(2) do
                            data_services.each do |name, ds|
                                pp.breakable
                                pp.text "#{name}: #{ds.model.name}"
                            end
                        end
                    end
                end
                super
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
            def new_submodel(name, system)
                klass = super()
                klass.name = name
                klass.system = system
                klass
            end

            # Returns the composition model that is parent to this one
            def parent_model
                parent = superclass
                while !parent.kind_of?(Class)
                    parent = parent.superclass
                end
                parent
            end

            # Enumerates all the specialized compositions that have been created
            # from this composition model.
            #
            # If +recursive+ is false, only the direct children are given.
            def each_specialization(recursive = true, &block)
                if !block_given?
                    return enum_for(:each_specialization, recursive)
                end

                specializations.each do |spec|
                    yield(spec.composition)
                    if recursive
                        spec.composition.each_specialization(&block)
                    end
                end
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

            ##
            # :attr: specializations
            #
            # The set of specializations defined at this level of the model
            # hierarchy, as an array of Specialization instances. See
            # #specialize for more details
            attribute(:specializations) { Array.new }

            def each_input
                if block_given?
                    each_exported_input do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_input)
                end
            end
            def find_input(name); find_exported_input(name) end

            def each_output
                if block_given?
                    each_exported_output do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_output)
                end
            end
            def find_output(name); find_exported_output(name) end

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

                parent_model = find_child(name) || CompositionChildDefinition.new
                if child_task_model
                    parent_task_model = parent_model.models.find { |m| m < Component }
                    if parent_task_model && !(child_task_model <= parent_task_model)
                        raise SpecError, "trying to overload #{parent_model.models} with #{child_model}"
                    end
                end

                # Delete from +parent_model+ everything that is already included
                # in +child_model+
                result = parent_model.dup
                result.models.delete_if { |parent_m| child_model.any? { |child_m| child_m <= parent_m } }
                result.models |= child_model.to_value_set
                result.dependency_options = result.dependency_options.merge(dependency_options)
                children[name] = result
            end

            # Add an element in this composition.
            #
            # This method adds a new element from the given component or data
            # service model. Raises ArgumentError if +model+ is of neither type.
            #
            # If an 'as' option is provided, this name will be used as the child
            # name. Otherwise, the basename of 'model' is used as the child
            # name. It will raise SpecError if the name is already used in this
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
            # composition. Otherwise, #add raises SpecError
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
            def add(model, options = Hash.new)
                if !model.kind_of?(Roby::TaskModelTag) && !(model.kind_of?(Class) && model < Component)
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
                options, dependency_options = Kernel.filter_options options, :as => model.name.gsub(/.*::/, '')

                add_child(options[:as], model, dependency_options)
                CompositionChild.new(self, options[:as])
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
                        specialize(child, model, :not => exclusions)
                    else
                        specialize(child, model)
                    end
                end

                child_constraints[child] << allowed_models
                filter_out_abstract_compositions

                abstract

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
            # FourWheelController data services.
            def specialize(child_name, child_model, options = Hash.new, &block)
                options = Kernel.validate_options options, :not => []
                if !options[:not].respond_to?(:to_ary)
                    options[:not] = [options[:not]]
                end

                if child_name.kind_of?(Module)
                    candidates = each_child.find_all { |name, child_definition| child_definition.models.include?(child_name) }
                    if candidates.size == 1
                        child_name = candidates[0][0]
                    end
                end

                child_name = if child_name.respond_to?(:to_str)
                                 child_name.to_str
                             else
                                 child_name.name.gsub(/^.*::/, '')
                             end

                if specialization = specializations.find { |m| m.specialized_children[child_name] == child_model }
                    if block
                        apply_specialization_block(child_name, child_model, block)
                    end
                    return specialization.composition
                end

                # Make sure we actually specialize ...
                if !has_child?(child_name)
                    raise SpecError, "there is no child called #{child_name} in #{self}"
                end
                parent_model = find_child(child_name)
                verify_acceptable_specialization(child_name, child_model, false)

                child_composition = system.composition(
                        "", :child_of => self, :register => false) do
                    add child_model, :as => child_name
                end
                child_composition.extend CompositionSpecializationModel
                
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

                    # Don't try to cross-specialize if the specialization is not
                    # valid.
                    valid = catch :invalid_selection do
                        spec.composition.verify_acceptable_specialization(child_name, child_model, false)
                    end
                    if valid
                        spec.composition.specialize(child_name, child_model, options)
                    end
                end

                filter_out_abstract_compositions
                if block
                    apply_specialization_block(child_name, child_model, block)
                end
                child_composition
            end

            # Looks for compositions which do not match the registered child
            # constraints (added with #constrain). Mark them as abstract.
            def filter_out_abstract_compositions
                each_specialization(false) do |spec|
                    child_constraints.each do |child_name, allowed_models|
                        allowed_models.each do |model_set|
                            child_spec = spec.find_child(child_name)
                            if child_spec
                                if !model_set.any? { |m| child_spec.fullfills?(m) }
                                    spec.abstract
                                    break
                                end
                            end
                        end
                    end
                end

                specializations.delete_if do |spec_model|
                    cmodel = spec_model.composition
                    cmodel.filter_out_abstract_compositions
                    if cmodel.abstract? && cmodel.specializations.empty?
                        true
                    else
                        false
                    end
                end
            end


            # Checks if an instance of +child_model+ would be acceptable as
            # the +child_name+ child of +self+.
            #
            # Raises SpecError if the choice is not acceptable
            #--
            # +user_call+ is for internal use only. If set to false, instead of
            # raising an exception, it will throw :invalid_selection. This is
            # meant to avoid the (costly) creation of the exception message in
            # cases we don't have to report to the user.
            def verify_acceptable_specialization(child_name, child_model, user_call = true)
                parent_models = find_child(child_name).models
                if parent_models.any? { |m| m <= child_model }
                    throw :invalid_selection if !user_call
                    raise SpecError, "#{child_model} does not specify a specialization of #{parent_models}"
                end
                if child_model < Component && parent_class = parent_models.find { |m| m < Component }
                    if !(child_model < parent_class)
                        throw :invalid_selection if !user_call
                        raise SpecError, "#{child_model} is not a subclass of #{parent_class}, cannot specialize #{child_name} with it"
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
                    specializations.each do |submodel|
                        pp.breakable
                        submodel = submodel.composition
                        specializations =
                            submodel.all_specializations.
                            map do |child_name, child_models|
                                "#{child_name}.is_a?(#{child_models.map(&:name).join(",")})"
                            end

                        pp.text specializations.join(";")
                        submodel.pretty_print_specializations(pp)
                    end
                end
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

            # Computes if +test_model+ is either equivalent or a specialization
            # of +base_model+
            #
            # Returns 0 if test_model and base_model represent the same overall
            # type, 1 if test_model is a specialization of base_model and nil if
            # they are not ordered.
            def compare_model_sets(base_model, test_model)
                equivalent_models = true

                # First, check if +test_model+ has a specialization and/or
                # equality on each models present in +base_model+
                specialized_models = ValueSet.new
                equal_models       = ValueSet.new
                base_model.each do |base_m|
                    has_specialized = false
                    has_equal       = false
                    test_model.each do |test_m|
                        if test_m < base_m
                            has_specialized = true
                            specialized_models << test_m
                        elsif test_m == base_m
                            has_equal = true
                            equal_models << test_m
                        end
                    end

                    if !has_specialized && !has_equal
                        # No relationship whatsoever
                        return
                    end
                end

                specialized_models -= equal_models
                equivalent_models = specialized_models.empty?

                if !equivalent_models || (specialized_models.size + equal_models.size) < test_model.size
                    1
                elsif equivalent_models
                    0
                end
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
            def find_most_specialized_compositions(engine, model_set, children_names)
                return model_set if children_names.empty?

                result = model_set.dup

                # Remove +composition+ if there is a specialized model in
                # +result+
                result.delete_if do |composition|
                    result.any? do |other_composition|
                        next if composition == other_composition

                        is_specialized = false
                        children_names.each do |child_name|
                            comparison = engine.compare_composition_child(
                                child_name, composition, other_composition)
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
                #
                # We push in +queue+ the compositions whose specializations
                # should be recursively discovered
                queue = []
                candidates = specializations.map { |spec| spec.composition }.
                    find_all do |child_composition|
                        # Note that the 'new' models in +child_composition+ are
                        # all in child_composition.children
                        recurse = true
                        valid   = false
                        child_composition.each_child do |child_name, child_definition|
                            selected_model = selected_models[child_name]
                            # no explicit selection for this child, ignore
                            next if !selected_model

                            selected_model = selected_model.first

                            # Look first at ourselves. If the component submodel
                            # is not an improvement on this particular child,
                            # do not select it
                            our_child_model = find_child(child_name).models
                            comparison_with_ourselves = compare_model_sets(our_child_model, child_definition.models)
                            comparison_with_selection = compare_model_sets(child_definition.models, [selected_model])
                            if !comparison_with_selection
                                recurse = false
                                valid = false
                                break
                            elsif comparison_with_selection && comparison_with_ourselves == 1
                                valid = true
                            end
                        end

                        queue << child_composition if recurse
                        valid
                    end

                # Recursively apply to find the specializations of
                # specializations
                queue.each do |composition|
                    candidates.concat(composition.
                          find_specializations(engine, selected_models))
                end

                Orocos::RobyPlugin.debug do
                    Orocos::RobyPlugin.debug "found #{candidates.size} specializations for #{name} against #{selected_models}"
                    candidates.each do |c|
                        Orocos::RobyPlugin.debug c.name
                    end
                    break
                end

                result = find_most_specialized_compositions(
                    engine, candidates, selected_models.keys)

                # Don't bother doing more if there is no ambiguity left
                if result.size < 2
                    return result
                end

                all_filtered_results = Hash.new

                # First, filter on the facets. If the user provides a facet, it
                # means we should prefer the required specialization.
                selected_models.each do |child_name, selected_child_model|
                    selected_child_model = selected_child_model.first
                    next if !selected_child_model.respond_to?(:selected_facet)

                    selected_facet = selected_child_model.selected_facet

                    preferred_models = result.find_all do |composition_model|
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
                        raise Ambiguous, "inconsistent use of faceted selection"
                    end
                    result = filtered_out
                end

                # We now look at default specializations. Compositions that have
                # certain specializations are preferred over other.
                each_default_specialization do |child_name, default_child_model|
                    preferred_models = result.find_all do |composition_model|
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
                    dependent_models = find_child(name).models
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
                            child_dest == in_child_name && mappings.keys.find { |p, _| p == in_port_name }
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
                    exported_inputs[name] = port
                when CompositionChildOutputPort
                    exported_outputs[name] = port
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
            def port(name)
                name = name.to_str
                (output_port(name) || input_port(name))
            end

            # Returns the composition's output port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def output_port(name); find_exported_output(name.to_str) end

            # Returns the composition's input port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def input_port(name); find_exported_input(name.to_str) end

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

            # Compares +model+ with the constraints declared for +child_name+.
            # Returns the set of unmatched constraints, or nil if all
            # constraints are met
            def match_child_constraints(child_name, model)
                missing_constraints = constraints_for(child_name).find_all do |model_set|
                    model_set.all? do |m|
                        !model.fullfills?(m)
                    end
                end
                if !missing_constraints.empty?
                    missing_constraints
                end
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
                result = find_most_specialized_compositions(engine, candidates, subselection.keys)
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
            
            # call-seq:
            #   find_selected_model_and_task(engine, child_name, selection) -> selected_object_name, child_model, child_task
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
                dependent_model = find_child(child_name).models

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
                elsif selected_object.kind_of?(DataServiceModel)
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
                dependent_model = find_child(child_name).models
                if !dependent_model
                    raise ArgumentError, "#{child_name} is not the name of a child of #{self}"
                end

                if !selected_model.fullfills?(dependent_model)
                    throw :invalid_selection if !user_call
                    raise SpecError, !user_call || "cannot select #{selected_model} for #{child_name} (#{dependent_model}): [#{selected_model}] is not a specialization of [#{dependent_model.to_a.join(", ")}]"
                end

                missing_constraints = match_child_constraints(child_name, selected_model)
                if missing_constraints
                    throw :invalid_selection if !user_call
                    raise SpecError, !user_call || "selected model #{selected_model} does not match the constraints for #{child_name}: it implements none of #{missing_constraints.first.map(&:name).join(", ")}"
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

            # Computes the port mappings required so that a task of
            # +child_model+ can be used to fullfill the services listed in
            # +data_services+. If +selected_object_name+ is non-nil, it is the the selected object (as
            # a string) given by the caller at instanciation time. It can be of
            # the form <task_name>.<source_name>, in which case it is used to
            # perform the selection
            #
            # The returned port mapping hash is of the form
            #
            #   source_port_name => child_port_name
            #
            def compute_port_mapping_for_selection(selected_object_name, child_model, data_services) # :nodoc:
                port_mappings = Hash.new

                if selected_object_name
                    _, *selection_name = selected_object_name.split '.'
                    selection_name = if selection_name.empty? then nil
                                     else selection_name.join(".")
                                     end
                end

                data_services.each do |data_service_model|
                    target_service =
                        child_model.find_matching_service(data_service_model, selection_name)

                    port_mappings.merge!(target_service.port_mappings) do |key, old, new|
                        if old != new
                            raise InternalError, "two different port mappings are required"
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
                each_child do |child_name, child_definition|
                    dependent_model = child_definition.models
                    selected_object_name, child_model, child_task =
                        find_selected_model_and_task(engine, child_name, selection)
                    verify_acceptable_selection(child_name, child_model, user_call)

                    # If the model is a plain data service (i.e. not a task
                    # model), we must map this service to a service on the
                    # selected task
                    data_services  = dependent_model.find_all { |m| m < DataService && !(m < Roby::Task) }
                    if !data_services.empty?
                        port_mappings =
                            compute_port_mapping_for_selection(selected_object_name, child_model, data_services)
                    end

                    Engine.debug do
                        " selected #{child_task || child_model} (#{port_mappings}) for #{child_name} (#{dependent_model.map(&:to_s).join(",")}) [#{data_services.empty?}]"
                    end
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
            # * a task, a data service or a data source
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
                    if port_mappings && !port_mappings.empty?
                        Orocos.debug { "applying port mappings for #{child_name}: #{port_mappings.inspect}" }
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
                    dependent_models    = find_child(child_name).models.to_a
                    dependent_arguments = dependent_models.inject(Hash.new) do |result, m|
                        result.merge(m.meaningful_arguments(child_task.arguments))
                    end
                    if dependent_models.size == 1
                        dependent_models = dependent_models.first
                    end

                    dependency_options = find_child(child_name).dependency_options
                    dependency_options = { :model => [dependent_models, dependent_arguments], :roles => role }.
                        merge(dependency_options)

                    Engine.info do
                        Engine.info "adding dependency #{self_task}"
                        Engine.info "    => #{child_task}"
                        Engine.info "   options; #{dependency_options}"
                        break
                    end
                    self_task.depends_on(child_task, dependency_options)
                end

                output_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_output do |output_name, port|
                    output_connections[ port.child.child_name ].
                        merge!([port.name, output_name] => Hash.new)
                end
                output_connections.each do |child_name, mappings|
                    children_tasks[child_name].forward_ports(self_task, mappings)
                end

                input_connections = Hash.new { |h, k| h[k] = Hash.new }
                each_exported_input do |input_name, port|
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
            # Yields the composition models that have been defined so far.
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
        #
        # See the CompositionModel for class-level methods
        class Composition < Component
            extend CompositionModel

            @name = "Orocos::RobyPlugin::Composition"

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
            inherited_enumerable(:exported_output, :exported_outputs, :map => true)  { Hash.new }
            # Inputs imported from this composition
            inherited_enumerable(:exported_input, :exported_inputs, :map => true)  { Hash.new }

            # Overriden from Roby::Task
            #
            # will return false if any of the children is not executable.
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
            #
            # It returns a component instance and a port name.
            def resolve_input_port(name) # :nodoc:
                if !(port = model.input_port(name.to_str))
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
                task = child_from_role(role)
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
                super

                if relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, mappings)
                end
            end

            # Called when a child is removed from this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def removing_child_object(child, relations) # :nodoc:
                super

                if relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, nil)
                end
            end

        end
    end
end

