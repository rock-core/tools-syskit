module Syskit
        # Generic representation of a configured component instance
        class InstanceRequirements
            extend Logger::Hierarchy
            include Logger::Hierarchy

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
            # A DI context that should be used to instanciate this task
            attr_reader :dependency_injection_context

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

            Dynamics = Struct.new :task, :ports do
                dsl_attribute 'period' do |value|
                    task.add_trigger('period', Float(value), 1)
                end
            end

            def plain?
                arguments.empty? && selections.empty?
            end

            def initialize(models = [])
                @base_model = Syskit.proxy_task_model_for(models)
                @model = base_model
                @arguments = Hash.new
                @selections = DependencyInjection.new
                @dependency_injection_context = DependencyInjectionContext.new
                @deployment_hints = Set.new
                @specialization_hints = Set.new
                @dynamics = Dynamics.new(NetworkGeneration::PortDynamics.new('Requirements'), [])
            end

            def initialize_copy(old)
                @model = old.model
                @base_model = old.base_model
                @arguments = old.arguments.dup
                @selections = old.selections.dup
                @deployment_hints = old.deployment_hints.dup
                @specialization_hints = old.specialization_hints.dup
                @dependency_injection_context = old.dependency_injection_context.dup
            end

            def self.from_object(object, original_requirements = Syskit::InstanceRequirements.new) 
                if object.plain?
                    object = object.dup
                    object.merge(original_requirements)
                    object
                else
                    object
                end
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                @base_model = base_model.merge(Syskit.proxy_task_model_for(new_models))
                narrow_model
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
                if self.service && service != self.service
                    raise ArgumentError, "#{self} already points to a service which is different from #{service}"
                end

                if !model.fullfills?(service.component_model)
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
                if model.respond_to?(:component_model) 
                    if model.fullfills?(service_type)
                        self
                    else nil
                    end
                elsif service = model.find_data_service_from_type(service_type)
                    result = dup
                    result.select_service(service)
                    result
                end
            end

            def as(models)
                models = Array(models) if !models.respond_to?(:each)
                Models::FacetedAccess.new(self, Syskit.proxy_task_model_for(models))
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
            def merge(other_spec)
                @base_model = base_model.merge(other_spec.base_model)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)

                @deployment_hints |= other_spec.deployment_hints
                @specialization_hints |= other_spec.specialization_hints
                @dependency_injection_context.concat(other_spec.dependency_injection_context)
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

                mappings.delete_if do |sel|
                    if sel.kind_of?(DependencyInjection)
                        selections.merge(sel)
                        true
                    end
                end

                explicit, defaults = DependencyInjection.partition_use_arguments(*mappings)
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
                new_mappings.add_explicit(explicit)
                explicit.each do |child_name, req|
                    next if !req.respond_to?(:fullfills?)
                    if child = model.find_child(child_name)
                        _, selected_m, _ = new_mappings.selection_for(child_name, child)
                        if !selected_m.fullfills?(child)
                            raise InvalidSelection.new(child_name, req, child), "#{req} is not a valid selection for #{child_name}. Was expecting something that provides #{child}"
                        end
                    end
                end

                selections.add_explicit(explicit)
                selections.add_defaults(defaults)
                composition_model = narrow_model || composition_model

                selections.each_selection_key do |obj|
                    if obj.respond_to?(:to_str)
                        # Two choices: either a child of the composition model,
                        # or a child of a child that is a composition itself
                        parts = obj.split('.')
                        first_part = parts.first
                        if !composition_model.has_child?(first_part)
                            raise "#{first_part} is not a known child of #{composition_model.name}"
                        end
                    end
                end

                self
            end

            # Specifies new arguments that must be set to the instanciated task
            def with_arguments(arguments)
                @arguments.merge!(arguments)
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
                @arguments[:conf] = conf
                self
            end

            # @deprecated use {#prefer_deployed_tasks} instead
            def use_deployments(*patterns)
                Roby.warn_deprecated "InstanceRequirements#use_deployments is deprecated. Use #prefer_deployed_tasks instead"
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
                        selection = self.resolved_dependency_injection.current_state.dup
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

                @model = model
                return model
            end

            attr_reader :required_host

            # Requires that this spec runs on the given process server, i.e.
            # that all the corresponding tasks are running on that process
            # server
            def on_server(name)
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

            # Returns the DI context used by this instance requirements task
            def resolved_dependency_injection
                context = DependencyInjectionContext.new
                context.concat(dependency_injection_context)
                context.push(selections)
                context
            end

            # Create a concrete task for this requirement
            def instanciate(plan, context = Syskit::DependencyInjectionContext.new, arguments = Hash.new)
                task_model = self.proxy_task_model

                context.save

                # Add a barrier for the names that our models expect. This is
                # required to avoid recursively reusing names (which was once
                # upon a time, and is a very confusing feature)
                barrier = Hash.new
                model.dependency_injection_names.each do |n|
                    if !selections.has_selection_for?(n)
                        barrier[n] = nil
                    end
                end
                selections = self.selections
                if !barrier.empty?
                    selections = selections.dup
                    selections.add_explicit(barrier)
                end
                context.concat(dependency_injection_context)
                context.push(selections)

                arguments = Kernel.normalize_options arguments
                arguments[:task_arguments] = self.arguments.merge(arguments[:task_arguments] || Hash.new)
                arguments[:specialization_hints] = specialization_hints | (arguments[:specialization_hints] || Set.new)
                task = task_model.instanciate(plan, context, arguments)
                task.requirements.merge(to_component_model)

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end
                model.bind(task)

            rescue InstanciationError => e
                e.instanciation_chain << self
                raise
            ensure context.restore
            end

            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            def fullfilled_model
                fullfilled = model.fullfilled_model
                task_model = fullfilled.find { |m| m <= Roby::Task } || Syskit::Component
                tags = fullfilled.find_all { |m| m.kind_of?(Syskit::Models::DataServiceModel) || m.kind_of?(Roby::Models::TaskServiceModel) }
                [task_model, tags, @arguments.dup]
            end

            def as_plan
                Syskit::InstanceRequirementsTask.subplan(self)
            end

            def to_s
                result = "#{base_model.short_name}"
                if model != base_model
                    result << "[narrowed to #{model.short_name}]"
                end
                if !selections.empty?
                    result << ".use(#{selections})"
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
                    if !selections.empty?
                        pp.breakable
                        pp.text ".use(#{selections})"
                    end
                    if !arguments.empty?
                        pp.breakable
                        pp.text ".with_arguments(#{arguments.map { |k, v| "#{k} => #{v}" }})"
                    end
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
                METHODS = [:with_arguments, :use_conf, :use_deployments, :period]
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
        end
end

