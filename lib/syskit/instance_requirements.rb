# frozen_string_literal: true

module Syskit
    # Generic representation of a configured component instance
    class InstanceRequirements
        extend Logger::Hierarchy
        include Logger::Hierarchy
        include Roby::DRoby::Unmarshallable

        dsl_attribute :doc

        # This requirement's name, mostly for debugging / display reasons
        # @return [String,nil]
        attr_accessor :name
        # The component model narrowed down from {base_model} using
        # {using_spec}
        attr_reader :model
        # The component model specified by #add
        attr_reader :base_model
        # Required arguments on the final task
        attr_reader :arguments
        # The model selection that can be used to instanciate this task, as
        # a DependencyInjection object
        attr_reader :selections
        protected :selections
        # The overall DI context (i.e. "globals")
        attr_reader :context_selections
        protected :context_selections
        # The set of pushed selections
        #
        # @see push_selections
        attr_reader :pushed_selections
        protected :pushed_selections

        # The deployments that should be used for self
        #
        # @return [Models::DeploymentGroup]
        attr_reader :deployment_group

        # A set of hints for deployment disambiguation
        #
        # @see prefer_deployed_tasks
        attr_reader :deployment_hints

        # A set of hints for specialization disambiguation
        #
        # @see prefer_specializations
        attr_reader :specialization_hints

        # Custom specification of task dynamics. This is not used as
        # requirements, but more exactly as hints to the dataflow dynamics
        # computations
        # @return [Dynamics]
        attr_reader :dynamics

        # The cached instanciated reqirement
        #
        # @return [nil,Roby::TemplatePlan]
        attr_reader :template

        # Whether instanciating this object can use a template plan
        #
        # Template plans cannot be used if the dependency injection
        # explicitely refers to a task
        attr_predicate :can_use_template?, true

        Dynamics = Struct.new :task, :ports do
            dsl_attribute "period" do |value|
                add_period_info(value, 1)
            end

            def add_period_info(period, sample_size = 1)
                task.add_trigger("period", Float(period), sample_size)
            end

            # Return an existing port dynamics object if it exists, or creates it
            #
            # @param [Strong] port_name
            # @return [NetworkGeneration::PortDynamics]
            def find_or_create_port_dynamics(port_name)
                port_name = port_name.to_str
                if (dynamics = ports[port_name])
                    return dynamics
                end

                ports[port_name] = NetworkGeneration::PortDynamics.new(port_name)
            end

            # (see InstanceRequirements#find_port_dynamics)
            def find_port_dynamics(port_name)
                ports[port_name.to_str]
            end

            def add_port_info(port_name, info)
                find_or_create_port_dynamics(port_name).merge(info)
            end

            # (see InstanceRequirements#add_port_period)
            def add_port_period(port_name, period, sample_count = 1)
                find_or_create_port_dynamics(port_name)
                    .add_trigger("period", period, sample_count)
            end

            def merge(other)
                task.merge(other.task)
                other.ports.each_key do |port_name|
                    ports[port_name] ||= NetworkGeneration::PortDynamics.new(port_name)
                end
                @ports = ports.merge(other.ports) do |_port_name, old, new|
                    old.merge(new)
                end
            end
        end

        def plain?
            arguments.empty? && selections.empty? && pushed_selections.empty?
        end

        def initialize(models = [])
            @base_model = Models::Placeholder.for(models)
            @model = base_model
            @arguments = {}
            @selections = DependencyInjection.new
            @pushed_selections = DependencyInjection.new
            @context_selections = DependencyInjection.new
            @deployment_hints = Set.new
            @specialization_hints = Set.new
            @dynamics = Dynamics.new(NetworkGeneration::PortDynamics.new("Requirements"),
                                     {})
            @can_use_template = true
            @deployment_group = Models::DeploymentGroup.new
        end

        # HACK: allows CompositionChild#to_instance_requirements to return a
        # HACK: problem InstanceRequirements object
        # HACK:
        # HACK: the proper fix would be to make the IR an attribute of
        # HACK: CompositionChild instead of a superclass
        def do_copy(old) # rubocop:disable Metrics/AbcSize
            @di = nil
            @template = old.template
            @abstract = old.abstract?
            @model = old.model
            @base_model = old.base_model
            @arguments = old.arguments.dup
            @selections = old.selections.dup
            @pushed_selections = old.pushed_selections.dup
            @deployment_hints = old.deployment_hints.dup
            @specialization_hints = old.specialization_hints.dup
            @context_selections = old.context_selections.dup
            @deployment_group = old.deployment_group.dup
            @can_use_template = old.can_use_template?
        end

        def initialize_copy(old)
            super
            do_copy(old)
        end

        def self.from_object(
            object, original_requirements = Syskit::InstanceRequirements.new
        )
            if object.plain?
                object = object.dup
                object.merge(original_requirements, keep_abstract: true)
            end
            object
        end

        # Add new models to the set of required ones
        def add_models(new_models)
            invalidate_template
            @base_model = base_model.merge(Models::Placeholder.for(new_models))
            narrow_model
        end

        def specialize
            new_ir = dup
            new_model = base_model.specialize
            new_ir.add_models([new_model])
            new_ir
        end

        def invalidate_dependency_injection
            @di = nil
            invalidate_template
        end

        def invalidate_template
            @template = nil
        end

        # @api private
        #
        # Plan object used to store a pre-calculated network structure
        class TemplatePlan < Roby::TemplatePlan
            # The root task (i.e. the task that self is directly representing)
            attr_accessor :root_task
        end

        # Map all selections registered in the use flags
        #
        # @yieldparam selection the selected model/task in the use flag
        # @yieldreturn the value that should replaces selection
        # @return [self]
        def map_use_selections!(&block)
            selections.map!(&block)
            pushed_selections.map!(&block)
            invalidate_dependency_injection
            invalidate_template
            self
        end

        # Returns a copy of these requirements with any service
        # specification strippped
        def to_component_model
            result = dup
            result.unselect_service
            result
        end

        # @deprecated use {#bind} instead
        def resolve(object)
            Roby.warn_deprecated "#{__method__} is deprecated, use " \
                                 "InstanceRequirements#bind instead"
            bind(object)
        end

        # @deprecated use {#try_bind} instead
        def try_resolve(task)
            Roby.warn_deprecated "#{__method__} is deprecated, use " \
                                 "InstanceRequirements#try_bind instead"
            try_bind(task)
        end

        # Maps the given task to the underlying model
        def bind(task)
            model.bind(task)
        end

        # Maps the given task to the underlying model
        #
        # Unlike {#bind}, it returns nil if the task cannot be mapped
        def try_bind(task)
            model.try_bind(task)
        end

        # The component model that is required through this object
        #
        # @return [Model<Component>]
        def component_model
            model = self.model.to_component_model
            if model.placeholder?
                model.proxied_component_model
            else
                model
            end
        end

        # Resolves the given port into a port that is attached to a
        # component model (NOT a service)
        def self_port_to_component_port(port)
            model.self_port_to_component_port(port).attach(to_component_model)
        end

        # If this object explicitly points to a bound service, return it
        #
        # @return [Models::BoundDataService,nil]
        def service
            if model.kind_of?(Models::BoundDataService)
                model
            elsif model.placeholder?
                ds = model.proxied_data_service_models
                model.find_data_service_from_type(ds.first) if ds.size == 1
            end
        end

        # Explicitely selects a given service on the task models required by
        # this task
        #
        # @param [Models::BoundDataService] the data service that should be
        #   selected
        # @raise [ArgumentError] if the provided service is not a service on
        #   a model in self (i.e. not a service of a component model in
        #   {#base_model}
        # @return [Models::BoundDataService] the selected service. If
        #   'service' is a service of a supermodel of a model in {#model},
        #   the resulting BoundDataService is attached to the actual model
        #   in {#model} and this return value is different from 'service'
        def select_service(service)
            validate_can_select_service(service)

            if service.kind_of?(InstanceRequirements)
                merge(service)
            elsif service.component_model.placeholder?
                select_placeholder_service(service)
            elsif (srv = base_model.find_data_service(service.name))
                @base_model = srv
                @model = srv.attach(@model)
            else
                @base_model = service.attach(model)
                narrow_model
            end
            self
        end

        # @api private
        #
        # Helper for {#select_service} for basic checks on whether this
        # InstanceRequirements is suitable to select the given service
        def validate_can_select_service(service)
            if self.service && !self.service.fullfills?(service)
                raise ArgumentError,
                      "#{self} already points to a service " \
                      "which is different from #{service}"
            end

            return if model.to_component_model.fullfills?(service.component_model)

            raise ArgumentError, "#{service} is not a service of #{self}"
        end

        # @api private
        #
        # Helper for {#select_service} in the case where the service being selected
        # is from a placeholder model
        #
        # In that case, we have to select from type and not from name
        def select_placeholder_service(service)
            if (srv = base_model.find_data_service_from_type(service.model))
                @base_model = srv
                @model = srv.attach(@model)
            else
                @base_model = model.find_data_service_from_type(service.model)
                narrow_model
            end
        end

        # Removes any service selection
        def unselect_service
            if base_model.respond_to?(:component_model)
                @base_model = base_model.component_model
            end
            @model = model.component_model if model.respond_to?(:component_model)
        end

        def has_data_service?(service_name)
            !!model.find_data_service(service_name)
        end

        # Finds a data service by name
        #
        # @param [String] service_name the service name
        # @return [InstanceRequirements,nil] the requirements with the requested
        #   data service selected or nil if there are no service with the
        #   requested name
        def find_data_service(service_name)
            return unless (service = model.find_data_service(service_name))

            result = dup
            result.select_service(service)
            result
        end

        # Finds the only data service that matches the given service type
        #
        # @param [Model<DataService>] the data service type
        # @return [InstanceRequirements,nil] this instance requirement object
        #   with the relevant service selected; nil if there are no matches
        # @raise [AmbiguousServiceSelection] if more than one service
        #   matches
        def find_data_service_from_type(service_type)
            if model.respond_to?(:find_data_service_from_type)
                if (service = model.find_data_service_from_type(service_type))
                    result = dup
                    result.select_service(service)
                    result
                end
            elsif model.fullfills?(service_type)
                self
            end
        end

        # Finds all the data services that match the given service type
        def find_all_data_services_from_type(service_type)
            if model.respond_to?(:find_all_data_services_from_type)
                model.find_all_data_services_from_type(service_type).map do |service|
                    result = dup
                    result.select_service(service)
                    result
                end
            elsif model.fullfills?(service_type)
                [self]
            else
                []
            end
        end

        def as(models)
            if service
                result = to_component_model
                result.select_service(service.as(models))
                result
            else
                models = Array(models) unless models.respond_to?(:each)
                Models::FacetedAccess.new(self, Models::Placeholder.for(models))
            end
        end

        # (see Models::BoundDataService#as_real_model)
        def as_real_model
            result = dup
            result.as_real_model!
            result
        end

        # (see Models::BoundDataService#as_real_model)
        def as_real_model!
            @base_model = base_model.as_real_model
            @model = model.as_real_model
            self
        end

        def has_child?(name)
            model.has_child?(name)
        end

        # Finds the composition's child by name
        #
        # @raise [ArgumentError] if this InstanceRequirements object does
        #   not refer to a composition
        def find_child(name)
            unless model.respond_to?(:find_child)
                raise ArgumentError, "#{self} is not a composition"
            end

            return unless (child = model.find_child(name))

            child.attach(self)
        end

        def find_input_port(name)
            return unless (p = model.find_input_port(name))

            p.attach(self)
        end

        def find_output_port(name)
            return unless (p = model.find_output_port(name))

            p.attach(self)
        end

        def has_port?(name)
            model.has_port?(name)
        end

        def find_port(name)
            find_input_port(name) || find_output_port(name)
        end

        def port_by_name(name)
            if (p = find_port(name))
                return p
            end

            existing = each_port.map(&:name).sort.join(", ")
            raise ArgumentError,
                  "#{self} has no port called #{name}, known ports are: #{existing}"
        end

        # Enumerates all of this component's ports
        def each_port(&block)
            return enum_for(:each_port) unless block_given?

            each_output_port(&block)
            each_input_port(&block)
        end

        def each_input_port
            return enum_for(:each_input_port) unless block_given?

            model.each_input_port do |p|
                yield(p.attach(self))
            end
        end

        def each_output_port
            return enum_for(:each_output_port) unless block_given?

            model.each_output_port do |p|
                yield(p.attach(self))
            end
        end

        # Return true if these requirements provide all of the required models
        def fullfills?(required_models)
            model.fullfills?(required_models)
        end

        # Merges +self+ and +other_spec+ into +self+
        #
        # Throws ArgumentError if the two specifications are not compatible
        # (i.e. can't be merged)
        def merge(other_spec, keep_abstract: false) # rubocop:disable Metrics/AbcSize
            if keep_abstract
                @abstract ||= other_spec.abstract?
            elsif !other_spec.abstract?
                @abstract = false
            end

            @base_model = base_model.merge(other_spec.base_model)
            @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                if v1 != v2
                    raise ArgumentError,
                          "cannot merge #{self} and #{other_spec}: " \
                          "argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                end

                v1
            end
            @selections.merge(other_spec.selections)
            @pushed_selections.merge(other_spec.pushed_selections)
            @context_selections.merge(other_spec.context_selections)
            @deployment_group.use_group(other_spec.deployment_group)

            @deployment_hints |= other_spec.deployment_hints
            @specialization_hints |= other_spec.specialization_hints

            @dynamics.merge(other_spec.dynamics)

            invalidate_dependency_injection
            invalidate_template

            # Call modules that could have been included in the class to
            # extend it
            super if defined? super

            narrow_model

            self
        end

        def hash
            model.hash
        end

        def eql?(other)
            other.kind_of?(InstanceRequirements) &&
                other.base_model == base_model &&
                other.selections == selections &&
                other.pushed_selections == pushed_selections &&
                other.arguments == arguments
        end

        def ==(other)
            eql?(other)
        end

        ##
        # :call-seq:
        #   use 'child_name' => 'component_model_or_device'
        #   use 'child_name' => ComponentModel
        #   use ChildModel => 'component_model_or_device'
        #   use ChildModel => ComponentModel
        #   use Model1, Model2, Model3
        #
        # Provides explicit selections for the children of compositions
        #
        # In the first two forms, provides an explicit selection for a
        # given child. The selection can be given either by name (name
        # of the model and/or of the selected device), or by directly
        # giving the model object.
        #
        # In the second two forms, provides an explicit selection for
        # any children that provide the given model. For instance,
        #
        #   use IMU => XsensImu::Task
        #
        # will select XsensImu::Task for any child that provides IMU
        #
        # Finally, the third form allows to specify preferences without
        # being specific about where to put them. If ambiguities are
        # found, and if only one of the possibility is listed there,
        # then that possibility will be selected. It has a lower
        # priority than the explicit selection.
        #
        # See also Composition#instanciate
        def use(*mappings)
            use_validate_is_composition_model

            invalidate_dependency_injection
            invalidate_template

            mappings.delete_if do |sel|
                if sel.kind_of?(DependencyInjection)
                    selections.merge(sel)
                    true
                end
            end

            explicit, defaults = DependencyInjection.partition_use_arguments(*mappings)
            explicit.each_value do |v|
                if v.kind_of?(Roby::Task) || v.kind_of?(BoundDataService)
                    @can_use_template = false
                end
            end

            use_issue_debug_messages(explicit, defaults)
            use_apply_normalized(explicit, defaults)

            self
        end

        def use_validate_is_composition_model
            return if composition_model?

            raise ArgumentError,
                  "#use is available only for compositions, " \
                  "got #{base_model.short_name}"
        end

        def use_apply_normalized(explicit, defaults)
            # !!! #add_explicit does not do any normalization. User-provided
            # !!! selections should always be added with #add
            selections.add(explicit)
            selections.add(*defaults)
            narrow_model

            use_validate_selection_keys
        end

        def use_issue_debug_messages(explicit, defaults)
            debug do
                debug "adding use mappings to #{self}"
                unless explicit.empty?
                    explicit.each do |key, obj|
                        debug "  #{key.short_name} => #{obj.short_name}"
                    end
                end
                debug "  #{defaults.map(&:short_name).join(', ')}" unless defaults.empty?
                break
            end
        end

        def use_validate_selection_keys
            composition_model = model.to_component_model

            selections.each_selection_key do |obj|
                next unless obj.respond_to?(:to_str)

                # Two choices: either a child of the composition model,
                # or a child of a child that is a composition itself
                child_name, = obj.split(".")

                use_validate_composition_child_selection(composition_model, child_name)
            end
        end

        def use_validate_composition_child_selection(composition_model, child_name)
            unless (child = composition_model.find_child(child_name))
                use_raise_no_such_child(composition_model, child_name)
            end

            direct_child_selection = selections.direct_selection_for(child_name)
            return unless direct_child_selection.respond_to?(:fullfills?)

            _, selected_m, = selections.selection_for(child_name, child)
            return if selected_m.fullfills?(child)

            raise InvalidSelection.new(child_name, selected_m, child),
                  "#{selected_m} is not a valid selection for " \
                  "#{child_name}. Was expecting something that provides " \
                  "#{child}"
        end

        def use_raise_no_such_child(composition_model, child_name)
            children =
                composition_model.each_child.with_object({}) do |(name, child_m), h|
                    h[name] = child_m
                end
            raise Roby::NoSuchChild.new(composition_model, child_name, children),
                  "#{child_name} is not a known child of #{composition_model.name}"
        end

        # Returns the simplest model representation for self
        #
        # It basically checks if {plain?} returns true or false. If self is
        # indeed plain, it returns the actual model class
        def simplest_model_representation
            if plain?
                model
            else
                self
            end
        end

        def push_selections
            invalidate_dependency_injection
            invalidate_template

            merger = DependencyInjectionContext.new
            merger.push pushed_selections
            merger.push selections
            @pushed_selections = merger.current_state
            @selections = DependencyInjection.new
            nil
        end

        # The instanciated task should be marked as abstract
        #
        # @return [self]
        def abstract
            invalidate_template
            @abstract = true
            self
        end

        # The instanciated task should not be marked as abstract
        #
        # This is the default. This method is here only to be able to un-set
        # {#abstract}
        #
        # @return [self]
        def not_abstract
            invalidate_template
            @abstract = false
            self
        end

        # Tests whether the instanciated task will be marked as abstract or
        # not
        def abstract?
            !!@abstract
        end

        # Optional dependency injection
        #
        # Once this is called, this {InstanceRequirements} object can be
        # used to inject into an optional dependency. This dependency that
        # will be fullfilled only if there is already a matching task
        # deployed in the plan
        #
        # This can only be meaningfully used when injected for a
        # composition's optional child (see {CompositionChild#optional})
        #
        # @return [self]
        def if_already_present
            invalidate_template
            abstract
        end

        # Specifies new arguments that must be set to the instanciated task
        def with_arguments(deprecated_arguments = nil, **arguments)
            with_arguments_handle_deprecated(deprecated_arguments, arguments)

            validate_arguments_are_marshallable(arguments)
            @arguments.merge!(arguments)
            self
        end

        def with_arguments_handle_deprecated(deprecated_arguments, arguments)
            deprecated_from_kw ||= Roby.sanitize_keywords(arguments)
            return unless deprecated_arguments || !deprecated_from_kw.empty?

            Roby.warn_deprecated(
                "InstanceRequirements#with_arguments: providing arguments using " \
                "a string is not supported anymore use key: value instead of " \
                "'key' => value"
            )
            normalized =
                (deprecated_arguments || {})
                .merge(deprecated_from_kw)
                .transform_keys(&:to_sym)
            arguments.merge!(normalized)
        end

        # @api private
        #
        # Helper for {#with_arguments} to validate that all argument values can be
        # marshalled
        def validate_arguments_are_marshallable(arguments)
            arguments.each do |k, v|
                unless v.droby_marshallable?
                    raise Roby::NotMarshallable,
                          "values used as task arguments must be marshallable, " \
                          "attempting to set #{k} to #{v} of class #{v.class}, " \
                          "which is not"
                end
            end
        end

        # Clear all arguments
        def with_no_arguments
            @arguments.clear
            self
        end

        # @deprecated use {#with_conf} instead
        def use_conf(*conf)
            Roby.warn_deprecated "InstanceRequirements#use_conf is deprecated. " \
                                 "Use #with_conf instead"
            with_conf(*conf)
        end

        # Specifies that the task that is represented by this requirement
        # should use the given configuration
        def with_conf(*conf)
            with_arguments(conf: conf)
            self
        end

        def reset_deployment_selection
            deployment_hints.clear
            @deployment_group = Models::DeploymentGroup.new
        end

        def use_configured_deployment(configured_deployment)
            invalidate_template
            deployment_group.register_configured_deployment(configured_deployment)
            self
        end

        # Declare the deployment that should be used for self
        def use_deployment(*spec, **options)
            invalidate_template
            deployment_group.use_deployment(*spec, **options)
            self
        end

        # Declare that an unmanaged task should be used for self
        def use_unmanaged_task(*spec, **options)
            invalidate_template
            deployment_group.use_unmanaged_task(*spec, **options)
            self
        end

        # Add deployments into the deployments this subnet should be using
        #
        # @param [Models::DeploymentGroup] deployment_group
        def use_deployment_group(deployment_group)
            invalidate_template
            self.deployment_group.use_group(deployment_group)
            self
        end

        # Add some hints to disambiguate deployment.
        #
        # Whenever there is an ambiguity during deployed task assignation,
        # the deployed task names that match the given pattern will be
        # preferred for tasks that are part of the subnet generated by this
        # instance requirements
        #
        # Note that if no ambiguities exist, these patterns are not used at
        # all
        #
        # @param [#===] patterns objects that can match strings (usually
        #   regular expressions)
        def prefer_deployed_tasks(*patterns)
            invalidate_template
            @deployment_hints |= patterns.to_set
            self
        end

        # Give information needed to disambiguate the specialization
        # selection
        #
        # Whenever a specialization ambiguity exists, the possible matches
        # will be evaluated against each selector given through this method.
        # Only the ones that match at least one will be selected in the end
        #
        # @param [{String=>Model<Component>}]
        # @return [self]
        def prefer_specializations(specialization_selectors)
            unless composition_model?
                raise ArgumentError,
                      "#{self} does not represent a composition, " \
                      "cannot use #prefer_specializations"
            end

            invalidate_template
            @specialization_hints << specialization_selectors
            self
        end

        # Computes the value of +model+ based on the current selection
        # (in #selections) and the base model specified in #add or
        # #define
        def narrow_model
            model = @base_model.to_component_model
            if composition_model? && !model.specializations.empty?
                model = narrow_composition_model(model)
            end

            # If base_model is a bound service, we need to select the same service
            # on the narrowed model
            model = base_model.attach(model) if base_model.respond_to?(:component_model)

            if @model != model
                invalidate_dependency_injection
                invalidate_template

                @model = model
            end
            model
        end

        # @api private
        #
        # Narrow (i.e. select specialization) for the given model given the information
        # stored in self
        def narrow_composition_model(base_model)
            debug do
                debug "narrowing model"
                debug "  from #{base_model.short_name}"
                break
            end

            context = log_nest(4) do
                selection = resolved_dependency_injection.dup
                selection.remove_unresolved
                DependencyInjectionContext.new(selection)
            end

            model = log_nest(2) do
                base_model.narrow(context, specialization_hints: specialization_hints)
            end

            debug do
                debug "  using #{model.short_name}"
                break
            end

            model
        end

        attr_reader :required_host

        # Requires that this spec runs on the given process server, i.e.
        # that all the corresponding tasks are running on that process
        # server
        def on_server(name)
            invalidate_template
            @required_host = name
        end

        # Returns a task that can be used in the plan as a placeholder for
        # this instance requirements
        #
        # The returned task is always marked as abstract
        def create_proxy_task
            task = component_model.new(**@arguments)
            task.required_host = required_host
            task.abstract = true
            task
        end

        # Returns the taks model that should be used to represent the result
        # of the deployment of this requirement in a plan
        # @return [Model<Roby::Task>]
        def placeholder_model
            model.to_component_model
        end

        # Adds a DI object to the resolution stack
        #
        # @param [DependencyInjection] di the new DI information
        # @return [void]
        def push_dependency_injection(injection)
            invalidate_dependency_injection
            invalidate_template

            merger = DependencyInjectionContext.new
            merger.push context_selections
            merger.push injection
            @context_selections = merger.current_state
        end

        # Returns the DI object used by this instance requirements task
        #
        # This is a cached result. Use {#compute_resolved_dependency_injection}
        # to always compute a new result
        #
        # @return [DependencyInjection]
        def resolved_dependency_injection
            return @di if @di

            context = DependencyInjectionContext.new
            context.push(context_selections)
            # Add a barrier for the names that our models expect. This is
            # required to avoid recursively reusing names (which was once
            # upon a time, and is a very confusing feature)
            barrier = Syskit::DependencyInjection.new
            barrier.add_mask(placeholder_model.dependency_injection_names)
            context.push(barrier)
            context.push(pushed_selections)
            context.push(selections)
            @di = context.current_state
        end

        # Create a concrete task for this requirement
        def instanciate(
            plan, context = Syskit::DependencyInjectionContext.new,
            task_arguments: {}, specialization_hints: {}, use_template: true
        )
            from_cache =
                context.empty? && specialization_hints.empty? &&
                use_template && can_use_template?
            task =
                if from_cache
                    instanciate_from_template(plan, task_arguments)
                else
                    instanciate_from_scratch(
                        context, plan, task_arguments, specialization_hints
                    )
                end

            post_instanciation_setup(task.to_task)
            model.bind(task)
        rescue InstanciationError => e
            e.instanciation_chain << self
            raise
        end

        # @api private
        #
        # Instanciates the network represented by self in the given plan without using
        # the cache
        #
        # Unlike {#instanciate_from_template}
        def instanciate_from_scratch(context, plan, task_arguments, specialization_hints)
            context.save
            context.push(resolved_dependency_injection)

            task_arguments = arguments.merge(task_arguments)
            specialization_hints =
                self.specialization_hints |
                specialization_hints
            placeholder_model.instanciate(
                plan, context,
                task_arguments: task_arguments,
                specialization_hints: specialization_hints
            )
        ensure
            context.restore
        end

        # @api private
        #
        # Instanciate the network represented by self in plan using a precomputed template
        #
        # The template plan will be computed if needed
        def instanciate_from_template(plan, extra_arguments)
            @template ||= compute_template

            mappings = @template.deep_copy_to(plan)
            root_task = mappings[@template.root_task]
            root_task.post_instanciation_setup(**arguments.merge(extra_arguments))
            model.bind(root_task)
        end

        # Compute the template and save it if needed
        #
        # @return [void]
        def update_template_if_needed
            return unless can_use_template?

            @template ||= compute_template # rubocop:disable Naming/MemoizedInstanceVariableName
        end

        # @api private
        #
        # Compute the template plan for the network represented by self
        #
        # @return [TemplatePlan]
        def compute_template
            base_requirements = dup.with_no_arguments
            template = TemplatePlan.new
            template.root_task =
                base_requirements
                .instanciate(template, use_template: false)
                .to_task

            if template_can_apply_merge?(template)
                merge_solver = NetworkGeneration::MergeSolver.new(template)
                merge_solver.merge_identical_tasks
                template.root_task = merge_solver.replacement_for(template.root_task)
            end

            template
        end

        def template_can_apply_merge?(template)
            template.each_task do |t|
                args = t.arguments
                next if args.static?

                args.each_delayed_argument do |_, v|
                    return false unless template_merge_allowed_argument?(v)
                end
            end
            true
        end

        def template_merge_allowed_argument?(value)
            case value
            when Roby::DefaultArgument
                true
            when Roby::DelayedArgumentFromObject
                # This is from(:parent_task), which is very common and not problematic
                value.__object__.nil? && value.__methods__.first == :parent_task
            else
                false
            end
        end

        # @api private
        #
        # Whether self has a template plan already computed
        def has_template?
            !!@template
        end

        # @api private
        #
        # Refinement of the task network generated by model instanciation
        def post_instanciation_setup(task)
            task_requirements = post_instanciation_compute_task_requirements
            task.update_requirements(
                task_requirements, name: name, keep_abstract: true
            )

            if required_host && task.respond_to?(:required_host=)
                task.required_host = required_host
            end
            task.abstract = true if abstract?
        end

        # @api private
        #
        # Helper for {#post_instanciation_setup} to compute task requirements
        def post_instanciation_compute_task_requirements
            task_requirements = to_component_model
            task_requirements.map_use_selections! do |sel|
                if sel && !Models.is_model?(sel) &&
                   !sel.kind_of?(DependencyInjection::SpecialDIValue)

                    sel.to_instance_requirements
                else
                    sel
                end
            end
            task_requirements
        end

        # List of task model and service models provided by instances of self
        #
        # @yieldparam [Models::Component,Models::DataServiceModel,
        #              Roby::Models::TaskServiceModel] model
        def each_fullfilled_model(&block)
            model.each_fullfilled_model(&block)
        end

        # Model that this instance requirement fullfills, that is can be used "as-if"
        #
        # @return [Class<Component>,
        #   [Models::DataServiceModel,Roby::Models::TaskServiceModel],Hash] a triplet
        #   of the component model represented by self, the list of service models (either
        #   syskit's data service or Roby's task service) and the arguments.
        def fullfilled_model
            fullfilled = model.fullfilled_model
            task_model = fullfilled.find { |m| m <= Roby::Task } || Syskit::Component
            tags = fullfilled.find_all do |m|
                m.kind_of?(Syskit::Models::DataServiceModel) ||
                    m.kind_of?(Roby::Models::TaskServiceModel)
            end
            [task_model.concrete_model, tags, @arguments.dup]
        end

        # Returns a plan pattern (main task and planning task) that will
        # deploy self
        #
        # The main task is an instance of {model} and the planning task an
        # instance of {InstanceRequirementsTask}.
        #
        # @return [Syskit::Component]
        def as_plan(**arguments)
            subplan_args = arguments.slice(:job_id)
            arguments.delete(:job_id)

            if arguments.empty?
                req = self
            else
                req = dup
                req.with_arguments(**arguments)
            end
            Syskit::InstanceRequirementsTask.subplan(req, **subplan_args)
        end

        def to_s
            PP.pp(self, +"").chomp
        end

        def pretty_print(pp)
            pretty_print_model(pp)
            pp.nest(2) do
                pretty_print_selections(pp, pushed_selections, use_suffix: "<0>")
                use_suffix = "<1>" unless pushed_selections.empty?

                pretty_print_selections(pp, selections, use_suffix: use_suffix)
                pretty_print_arguments(pp)
            end
        end

        def pretty_print_model(pp)
            if model == base_model
                pp.text model.to_s
            else
                pp.text "#{model}(from #{base_model})"
            end
        end

        def pretty_print_selections(pp, selections, use_suffix: "")
            return if selections.empty?

            pp.text ".use#{use_suffix}("
            pp.nest(2) do
                pp.breakable
                pp.seplist(selections.defaults) do |val|
                    val.pretty_print(pp)
                end
                pp.seplist(selections.explicit) do |k, v|
                    pp.text "#{k} => "
                    v.pretty_print(pp)
                end
            end
            pp.breakable
            pp.text ")"
        end

        def pretty_print_arguments(pp)
            return if arguments.empty?

            pp.breakable
            pp.text ".with_arguments("
            pp.nest(2) do
                pp.breakable
                pp.seplist(arguments) do |k, v|
                    pp.text "#{k} => #{v}"
                end
            end
        end

        def each_child
            return enum_for(__method__) unless block_given?

            unless composition_model?
                raise "cannot call #each_child on #{self} as it does not " \
                      "represent a composition model"
            end

            resolved_di = resolved_dependency_injection
            model.each_child do |child_name, _|
                selected_child, = model.find_child_model_and_task(
                    child_name, resolved_di
                )
                yield(child_name, selected_child)
            end
        end

        def has_through_method_missing?(name)
            MetaRuby::DSLs.has_through_method_missing?(
                self, name,
                "_srv" => :has_data_service?,
                "_child" => :has_child?,
                "_port" => :has_port?
            ) || super
        end

        def find_through_method_missing(name, args)
            MetaRuby::DSLs.find_through_method_missing(
                self, name, args,
                "_srv" => :find_data_service,
                "_child" => :find_child,
                "_port" => :find_port
            ) || super
        end

        include MetaRuby::DSLs::FindThroughMethodMissing

        # Generates the InstanceRequirements object that represents +self+
        # best
        #
        # @return [Syskit::InstanceRequirements]
        def to_instance_requirements
            self
        end

        def each_required_service_model
            return enum_for(:each_required_service_model) unless block_given?

            model.each_required_model do |m|
                yield(m) if m.kind_of?(Syskit::Models::DataServiceModel)
            end
        end

        def each_required_model(&block)
            return enum_for(:each_required_model) unless block_given?

            model.each_required_model(&block)
        end

        # Tests if these requirements explicitly point to a component model
        def component_model?
            if model.placeholder?
                model.proxied_component_model != Syskit::Component
            else
                true
            end
        end

        # Tests if these requirements explicitly point to a composition model
        def composition_model?
            base_model.to_component_model.fullfills?(Syskit::Composition)
        end

        def period(period, sample_size = 1)
            dynamics.add_period_info(period, sample_size)
            self
        end

        # Returns the port dynamics defined for a given port, or nil if none is
        # registered
        #
        # @param [String] port_name
        # @return [NetworkGeneration::PortDynamics,nil]
        # @see add_port_period
        def find_port_dynamics(port_name)
            dynamics.find_port_dynamics(port_name.to_s)
        end

        # Declare the period of a port
        #
        # When computing dataflow, this overrides propagated values
        #
        # @param [String] port_name
        # @param [Float] period the period in seconds
        # @param [Integer] sample_count how many samples are written each
        #   time
        # @return [self]
        def add_port_period(port_name, period, sample_count = 1)
            unless model.has_port?(port_name)
                raise ArgumentError, "#{model} has not port called #{port_name}"
            end

            dynamics.add_port_period(port_name, period, sample_count)
            self
        end

        # This module can be used to extend other objects so that instance
        # requirements methods are directly available on that object
        #
        # The object must define #to_instance_requirements
        module Auto
            METHODS = %I[
                with_arguments with_conf prefer_deployed_tasks
                use_conf use_deployments period
            ].freeze

            METHODS.each do |m|
                class_eval <<~CODE, __FILE__, __LINE__ + 1
                    def #{m}(*args, **kw, &block)                          # def with_arguments(**kw)
                        to_instance_requirements.#{m}(*args, **kw, &block) #    to_instance_requirements.with_arguments(**kw)
                    end                                                    # end
                CODE
            end
        end

        # Representation of a Syskit network in a coordination model (e.g. action state
        # machines)
        class CoordinationTask < Roby::Coordination::Models::TaskWithDependencies
            def initialize(requirements)
                super(requirements.placeholder_model)
                @requirements = requirements
            end

            # Called by the state machine implementation to create a Roby::Task
            # instance that will perform the state's actions
            def instanciate(_plan, variables = {})
                arguments = @requirements.arguments.transform_values do |value|
                    if value.respond_to?(:evaluate)
                        value.evaluate(variables)
                    else
                        value
                    end
                end
                @requirements.as_plan(**arguments)
            end
        end

        # Normalization method used by coordination models (e.g. action state machines)
        def to_coordination_task(_task_model)
            CoordinationTask.new(self)
        end

        def selected_for(requirements)
            Syskit::InstanceSelection.new(
                nil, self, requirements.to_instance_requirements
            )
        end

        def to_action_model(doc = self.doc)
            action_model = Actions::Models::Action.new(self, doc)
            action_model.name = name
            action_model.returns(model.to_component_model)

            task_model = component_model
            root_model = [TaskContext, Composition, Component].find do |m|
                task_model <= m
            end
            task_arguments = task_model.arguments.to_a - root_model.arguments.to_a
            task_arguments.each do |arg_name|
                to_action_model_define_argument(action_model, task_model, arg_name)
            end
            action_model
        end

        # @api private
        #
        # Transfer information about a task argument to the given action model, helper
        # to {#to_action_model}
        def to_action_model_define_argument(action_model, task_model, arg_name)
            arg = task_model.find_argument(arg_name)
            doc = to_action_model_arg_doc(arg, task_model)

            if arguments.key?(arg_name)
                action_model.optional_arg(arg_name, doc, arguments[arg_name])
            elsif arg.has_default?
                default_argument = arg.default
                if default_argument.kind_of?(Roby::DefaultArgument)
                    default_argument = default_argument.value
                elsif arg.has_delayed_default?
                    default_argument = nil
                end
                action_model.optional_arg(arg_name, doc, default_argument)
            else
                action_model.required_arg(arg_name, doc, example: arg.example)
            end
        end

        def to_action_model_arg_doc(arg, task_model)
            arg.doc || "#{arg.name} argument of #{task_model.name}"
        end

        def to_action
            to_action_model.new
        end

        # Request to run this task model with the given name
        def deployed_as(name, **options)
            use_deployment_group(
                model.to_deployment_group(name, **options)
            )
            self
        end

        # Deploy the network represented by self using the given deployment(s)
        def deploy_with(*names, **options)
            use_deployment(*names, **options)
            self
        end

        # Request to run this task model with the given name, as an unmanaged task
        #
        # Unmanaged tasks are started externally to Syskit, but Syskit still
        # manages the task's configuration and state changes
        def deployed_as_unmanaged(name, **options)
            use_unmanaged_task({ model.concrete_model => name }, **options)
            self
        end
    end
end
