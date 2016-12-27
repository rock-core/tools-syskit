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
                dsl_attribute 'period' do |value|
                    task.add_trigger('period', Float(value), 1)
                end

                def merge(other)
                    task.merge(other.task)
                    other.ports.each_key { |port_name| ports[port_name] ||= PortDynamics.new(port_name) }
                    ports.merge(other.ports) do |port_name, old, new|
                        old.merge(new)
                    end
                end
            end

            def plain?
                arguments.empty? && selections.empty? && pushed_selections.empty?
            end

            def initialize(models = [])
                @base_model = Syskit.proxy_task_model_for(models)
                @model = base_model
                @arguments = Hash.new
                @selections = DependencyInjection.new
                @pushed_selections = DependencyInjection.new
                @context_selections = DependencyInjection.new
                @deployment_hints = Set.new
                @specialization_hints = Set.new
                @dynamics = Dynamics.new(NetworkGeneration::PortDynamics.new('Requirements'), Hash.new)
                @can_use_template = true
            end

            # HACK: allows CompositionChild#to_instance_requirements to return a
            # HACK: problem InstanceRequirements object
            # HACK:
            # HACK: the proper fix would be to make the IR an attribute of
            # HACK: CompositionChild instead of a superclass
            def do_copy(old)
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
                @can_use_template = old.can_use_template?
            end

            def initialize_copy(old)
                super
                do_copy(old)
            end

            def self.from_object(object, original_requirements = Syskit::InstanceRequirements.new) 
                if object.plain?
                    object = object.dup
                    object.merge(original_requirements, keep_abstract: true)
                    object
                else
                    object
                end
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                invalidate_template
                @base_model = base_model.merge(Syskit.proxy_task_model_for(new_models))
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

            class TemplatePlan < Roby::TemplatePlan
                attr_accessor :root_task
            end

            # Map all selections registered in the use flags
            #
            # @yieldparam selection the selected model/task in the use flag
            # @yieldreturn the value that should replaces selection
            # @return [self]
            def map_use_selections!
                selections.map! do |value|
                    yield(value)
                end
                pushed_selections.map! do |value|
                    yield(value)
                end
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

            # The component model that is required through this object
            #
            # @return [Model<Component>]
            def component_model
                model = self.model.to_component_model
                if model.respond_to?(:proxied_task_context_model)
                    return model.proxied_task_context_model
                else return model
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
                elsif model.respond_to?(:proxied_data_services)
                    ds = model.proxied_data_services
                    if ds.size == 1
                        return model.find_data_service_from_type(ds.first)
                    end
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
                if self.service && !self.service.fullfills?(service)
                    raise ArgumentError, "#{self} already points to a service which is different from #{service}"
                end

                if !model.to_component_model.fullfills?(service.component_model)
                    raise ArgumentError, "#{service} is not a service of #{self}"
                end
                if service.component_model.respond_to?(:proxied_data_services)
                    if srv = base_model.find_data_service_from_type(service.model)
                        @base_model = srv
                        @model = srv.attach(model)
                    else
                        @base_model = model.find_data_service_from_type(service.model)
                        @model = base_model
                    end
                else
                    if srv = base_model.find_data_service(service.name)
                        @base_model = srv
                        @model = srv.attach(model)
                    else
                        @base_model = service.attach(model)
                        @model = base_model
                    end
                end
                self
            end

            # Removes any service selection
            def unselect_service
                if base_model.respond_to?(:component_model)
                    @base_model = base_model.component_model
                end
                if model.respond_to?(:component_model)
                    @model = model.component_model
                end
            end

            # Finds a data service by name
            #
            # @param [String] service_name the service name
            # @return [InstanceRequirements,nil] the requirements with the requested
            #   data service selected or nil if there are no service with the
            #   requested name
            def find_data_service(service_name)
                if service = model.find_data_service(service_name)
                    result = dup
                    result.select_service(service)
                    result
                end
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
                    if service = model.find_data_service_from_type(service_type)
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
                    models = Array(models) if !models.respond_to?(:each)
                    Models::FacetedAccess.new(self, Syskit.proxy_task_model_for(models))
                end
            end

            def as_real_model
                result = dup
                result.as_real_model!
                result
            end

            def as_real_model!
                @base_model = base_model.as_real_model
                @model = model.as_real_model
                self
            end

            # Finds the composition's child by name
            #
            # @raise [ArgumentError] if this InstanceRequirements object does
            #   not refer to a composition
            def find_child(name)
                if !model.respond_to?(:find_child)
                    raise ArgumentError, "#{self} is not a composition"
                end
                if child = model.find_child(name)
                    return child.attach(self)
                end
            end

            def find_input_port(name)
                if p = model.find_input_port(name)
                    p.attach(self)
                end
            end

            def find_output_port(name)
                if p = model.find_output_port(name)
                    p.attach(self)
                end
            end

            def find_port(name)
                find_input_port(name) || find_output_port(name)
            end

            def port_by_name(name)
                if p = find_port(name)
                    p
                else raise ArgumentError, "#{self} has no port called #{name}, known ports are: #{each_port.map(&:name).sort.join(", ")}"
                end
            end

            # Enumerates all of this component's ports
            def each_port(&block)
                return enum_for(:each_port) if !block_given?
                each_output_port(&block)
                each_input_port(&block)
            end

            def each_input_port
                return enum_for(:each_input_port) if !block_given?
                model.each_input_port do |p|
                    yield(p.attach(self))
                end
            end

            def each_output_port
                return enum_for(:each_output_port) if !block_given?
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
            def merge(other_spec, keep_abstract: false)
                if keep_abstract
                    @abstract ||= other_spec.abstract?
                elsif !other_spec.abstract?
                    @abstract = false 
                end

                @base_model = base_model.merge(other_spec.base_model)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)
                @pushed_selections.merge(other_spec.pushed_selections)
                @context_selections.merge(other_spec.context_selections)

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

            def hash; model.hash end
            def eql?(obj)
                obj.kind_of?(InstanceRequirements) &&
                    obj.base_model == base_model &&
                    obj.selections == selections &&
                    obj.pushed_selections == pushed_selections &&
                    obj.arguments == arguments
            end
            def ==(obj)
                eql?(obj)
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
                if !(model <= Syskit::Composition)
                    raise ArgumentError, "#use is available only for compositions, got #{base_model.short_name}"
                end

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

                debug do
                    debug "adding use mappings to #{self}"
                    if !explicit.empty?
                        explicit.each do |key, obj|
                            debug "  #{key.short_name} => #{obj.short_name}"
                        end
                    end
                    if !defaults.empty?
                        debug "  #{defaults.map(&:short_name).join(", ")}"
                    end
                    break
                end

                # Validate the new mappings first
                new_mappings = selections.dup
                # !!! #add_explicit does not do any normalization. User-provided
                # !!! selections should always be added with #add
                new_mappings.add(explicit)
                explicit.each_key do |child_name|
                    req = new_mappings.explicit[child_name]
                    next if !req.respond_to?(:fullfills?)
                    if child = model.find_child(child_name)
                        _, selected_m, _ = new_mappings.selection_for(child_name, child)
                        if !selected_m.fullfills?(child)
                            raise InvalidSelection.new(child_name, req, child), "#{req} is not a valid selection for #{child_name}. Was expecting something that provides #{child}"
                        end
                    end
                end

                # See comment about #add_explicit vs. #add above
                selections.add(explicit)
                selections.add(*defaults)
                composition_model = narrow_model || composition_model

                selections.each_selection_key do |obj|
                    if obj.respond_to?(:to_str)
                        # Two choices: either a child of the composition model,
                        # or a child of a child that is a composition itself
                        parts = obj.split('.')
                        first_part = parts.first
                        if !composition_model.has_child?(first_part)
                            children = Hash.new
                            composition_model.each_child do |name, child|
                                children[name] = child
                            end
                            raise Roby::NoSuchChild.new(composition_model, first_part, children), "#{first_part} is not a known child of #{composition_model.name}"
                        end
                    end
                end

                self
            end

            # Returns the simplest model representation for self
            #
            # It basically checks if {plain?} returns true or false. If self is
            # indeed plain, it returns the actual model class
            def simplest_model_representation
                if plain?
                    return model
                else return self
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
            def with_arguments(arguments)
                arguments.each do |k, v|
                    if !v.droby_marshallable?
                        raise Roby::NotMarshallable, "values used as task arguments must be marshallable, attempting to set #{k} to #{v}, which is not"
                    end
                end
                @arguments.merge!(arguments)
                self
            end

            # Clear all arguments
            def with_no_arguments
                @arguments.clear
                self
            end

            # @deprecated use {#with_conf} instead
            def use_conf(*conf)
                Roby.warn_deprecated "InstanceRequirements#use_conf is deprecated. Use #with_conf instead"
                with_conf(*conf)
            end

            # Specifies that the task that is represented by this requirement
            # should use the given configuration
            def with_conf(*conf)
                with_arguments(conf: conf)
                self
            end

            # @deprecated use {#prefer_deployed_tasks} instead
            def use_deployments(*patterns)
                Roby.warn_deprecated "InstanceRequirements#use_deployments is deprecated. Use #prefer_deployed_tasks instead"
                invalidate_template
                prefer_deployed_tasks(*patterns)
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
                if !composition_model?
                    raise ArgumentError, "#{self} does not represent a composition, cannot use #prefer_specializations"
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
                    debug do
                        debug "narrowing model"
                        debug "  from #{model.short_name}"
                        break
                    end

                    context = log_nest(4) do
                        selection = self.resolved_dependency_injection.dup
                        selection.remove_unresolved
                        DependencyInjectionContext.new(selection)
                    end

                    model = log_nest(2) do
                        model.narrow(context, :specialization_hints => specialization_hints)
                    end

                    debug do
                        debug "  using #{model.short_name}"
                        break
                    end
                end
                if base_model.respond_to?(:component_model)
                    model = base_model.attach(model)
                end

                if @model != model
                    invalidate_dependency_injection
                    invalidate_template

                    @model = model
                end
                return model
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
                task = component_model.new(@arguments)
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Returns the taks model that should be used to represent the result
            # of the deployment of this requirement in a plan
            # @return [Model<Roby::Task>]
            def proxy_task_model
                model.to_component_model
            end

            # Adds a DI object to the resolution stack
            #
            # @param [DependencyInjection] di the new DI information
            # @return [void]
            def push_dependency_injection(di)
                invalidate_dependency_injection
                invalidate_template

                merger = DependencyInjectionContext.new
                merger.push context_selections
                merger.push di
                @context_selections = merger.current_state
            end

            # Returns the DI object used by this instance requirements task
            #
            # @return [DependencyInjection]
            def resolved_dependency_injection
                if !@di
                    context = DependencyInjectionContext.new
                    context.push(context_selections)
                    # Add a barrier for the names that our models expect. This is
                    # required to avoid recursively reusing names (which was once
                    # upon a time, and is a very confusing feature)
                    barrier = Syskit::DependencyInjection.new
                    barrier.add_mask(self.proxy_task_model.dependency_injection_names)
                    context.push(barrier)
                    context.push(pushed_selections)
                    context.push(selections)
                    @di = context.current_state
                end
                @di
            end

            def compute_template
                base_requirements = dup.with_no_arguments
                template = TemplatePlan.new
                template.root_task = base_requirements.
                    instanciate(template, use_template: false).
                    to_task
                merge_solver = NetworkGeneration::MergeSolver.new(template)
                merge_solver.merge_identical_tasks
                template.root_task = merge_solver.replacement_for(template.root_task)
                @template = template
            end

            def instanciate_from_template(plan)
                if !@template
                    compute_template
                end

                mappings = @template.deep_copy_to(plan)
                root_task = mappings[@template.root_task] 
                root_task.assign_arguments(arguments)
                return model.bind(root_task)
            end
            def has_template?
                !!@template
            end

            # Create a concrete task for this requirement
            def instanciate(plan, context = Syskit::DependencyInjectionContext.new, task_arguments: Hash.new, specialization_hints: Hash.new, use_template: true)
                if context.empty? && task_arguments.empty? && specialization_hints.empty? && use_template && can_use_template?
                    from_cache = true
                    return instanciate_from_template(plan)
                end

                task_model = self.proxy_task_model

                context.save
                context.push(resolved_dependency_injection)

                task_arguments = self.arguments.merge(task_arguments)
                specialization_hints = self.specialization_hints | specialization_hints
                task = task_model.instanciate(plan, context, task_arguments: task_arguments, specialization_hints: specialization_hints)
                task_requirements = to_component_model
                task_requirements.map_use_selections! do |sel|
                    if sel && !Models.is_model?(sel)
                        sel.to_instance_requirements
                    else sel
                    end
                end
                task.requirements.merge(task_requirements)

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end
                task.abstract = true if abstract?
                model.bind(task)

            rescue InstanciationError => e
                e.instanciation_chain << self
                raise
            ensure
                context.restore if !from_cache
            end

            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            def fullfilled_model
                fullfilled = model.fullfilled_model
                task_model = fullfilled.find { |m| m <= Roby::Task } || Syskit::Component
                tags = fullfilled.find_all { |m| m.kind_of?(Syskit::Models::DataServiceModel) || m.kind_of?(Roby::Models::TaskServiceModel) }
                [task_model.concrete_model, tags, @arguments.dup]
            end

            # Returns a plan pattern (main task and planning task) that will
            # deploy self
            #
            # The main task is an instance of {model} and the planning task an
            # instance of {InstanceRequirementsTask}.
            #
            # @return [Syskit::Component]
            def as_plan(arguments = Hash.new)
                Syskit::InstanceRequirementsTask.subplan(self, arguments)
            end

            def to_s
                result = "#{base_model.short_name}"
                if model != base_model
                    result << "[narrowed to #{model.short_name}]"
                end
                if !pushed_selections.empty?
                    result << ".use<0>(#{pushed_selections})"
                    use_suffix = "<1>"
                end
                if !selections.empty?
                    result << ".use#{use_suffix}(#{selections})"
                end
                if !arguments.empty?
                    result << ".with_arguments(#{arguments.map { |k, v| "#{k} => #{v}" }})"
                end
                result
            end

            def pretty_print(pp)
                if model != base_model
                    pp.text "#{model}(from #{base_model})"
                else
                    pp.text "#{model}"
                end
                pp.nest(2) do
                    if !pushed_selections.empty?
                        pp.breakable
                        pp.text ".use<0>(#{pushed_selections})"
                        use_suffix = "<1>"
                    end
                    if !selections.empty?
                        pp.breakable
                        pp.text ".use#{use_suffix}(#{selections})"
                    end
                    if !arguments.empty?
                        pp.breakable
                        pp.text ".with_arguments(#{arguments.map { |k, v| "#{k} => #{v}" }.join(", ")})"
                    end
                end
            end

            def each_child
                return enum_for(__method__) if !block_given?
                if !composition_model?
                    raise RuntimeError, "cannot call #each_child on #{self} as it does not represent a composition model"
                end
                resolved_di = resolved_dependency_injection
                model.each_child do |child_name, _|
                    selected_child, _ = model.find_child_model_and_task(
                        child_name, resolved_di)
                    yield(child_name, selected_child)
                end
            end

            def method_missing(method, *args)
                if !args.empty? || block_given?
                    return super
                end

		case method.to_s
                when /^(\w+)_srv$/
                    service_name = $1
                    if srv = find_data_service(service_name)
                        return srv
                    end
                    raise NoMethodError, "#{model.short_name} has no data service called #{service_name}"
                when /^(\w+)_child$/
                    child_name = $1
                    if child = find_child(child_name)
                        return child
                    end
                    raise NoMethodError, "#{model.short_name} has no child called #{child_name}"
                when /^(\w+)_port$/
                    port_name = $1
                    if port = find_port(port_name)
                        return port
                    end
                    raise NoMethodError, "no port called #{port_name} in #{model}"
                end
                super(method.to_sym, *args)
            end

            # Generates the InstanceRequirements object that represents +self+
            # best
            #
            # @return [Syskit::InstanceRequirements]
            def to_instance_requirements
                self
            end

            def each_required_service_model
                return enum_for(:each_required_service_model) if !block_given?
                model.each_required_model do |m|
                    yield(m) if m.kind_of?(Syskit::Models::DataServiceModel)
                end
            end

            def each_required_model
                return enum_for(:each_required_model) if !block_given?
                model.each_required_model do |m|
                    yield(m)
                end
            end

            # Tests if these requirements explicitly point to a component model
            def component_model?
                if model.respond_to?(:proxied_task_context_model)
                    model.proxied_task_context_model
                else true
                end
            end

            # Tests if these requirements explicitly point to a composition model
            def composition_model?
                base_model.fullfills?(Syskit::Composition)
            end

            def period(value)
                dynamics.period(value)
                self
            end

            def bind(object)
                model.bind(object)
            end

            # This module can be used to extend other objects so that instance
            # requirements methods are directly available on that object
            #
            # The object must define #to_instance_requirements
            module Auto
                METHODS = [:with_arguments, :with_conf, :prefer_deployed_tasks, :use_conf, :use_deployments, :period]
                METHODS.each do |m|
                    class_eval <<-EOD
                    def #{m}(*args, &block)
                        to_instance_requirements.send(m, *args, &block)
                    end
                    EOD
                end
            end

            def to_coordination_task(task_model)
                Roby::Coordination::Models::TaskFromAsPlan.new(self, proxy_task_model)
            end

            def selected_for(requirements)
                Syskit::InstanceSelection.new(nil, self, requirements.to_instance_requirements)
            end

            def to_action_model(doc = self.doc)
                action_model = Actions::Models::Action.new(self, doc)
                action_model.name = name
                action_model.returns(model.to_component_model)

                task_model = component_model
                root_model = [TaskContext, Composition, Component].find { |m| task_model <= m }
                task_arguments = task_model.arguments.to_a - root_model.arguments.to_a
                task_arguments.each do |arg_name|
                    if task_model.default_argument(arg_name) || arguments.has_key?(arg_name.to_s)
                        action_model.optional_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                    else
                        action_model.required_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                    end
                end
                action_model
            end

            def to_action
                to_action_model.new
            end
        end
end

