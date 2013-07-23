module Syskit
        # Generic representation of a configured component instance
        class InstanceRequirements
            extend Logger::Hierarchy
            include Logger::Hierarchy

            # The component model narrowed down from +base_models+ using
            # +using_spec+
            attr_reader :models
            # The component model specified by #add
            attr_reader :base_models
            # Required arguments on the final task
            attr_reader :arguments
            # The model selection that can be used to instanciate this task, as
            # a DependencyInjection object
            attr_reader :selections
            # A DI context that should be used to instanciate this task
            attr_reader :dependency_injection_context
            # If set, this requirements points to a specific service, not a
            # specific task. Use #select_service to select.
            attr_reader :service

            # A set of hints for deployment disambiguation (as matchers on the
            # deployment names). New hints can be added with #use_deployments
            attr_reader :deployment_hints

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
                @models    = @base_models = models.to_value_set
                @arguments = Hash.new
                @selections = DependencyInjection.new
                @dependency_injection_context = DependencyInjectionContext.new
                @deployment_hints = Set.new
                @dynamics = Dynamics.new(NetworkGeneration::PortDynamics.new('Requirements'), [])
            end

            def initialize_copy(old)
                @models = old.models.dup
                @base_models = old.base_models.dup
                @arguments = old.arguments.dup
                @selections = old.selections.dup
                @deployment_hints = old.deployment_hints.dup
                @dependency_injection_context = old.dependency_injection_context.dup
                @service = service
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
                new_models = new_models.dup
                new_models.delete_if { |m| @base_models.any? { |bm| bm.fullfills?(m) } }
                base_models.delete_if { |bm| new_models.any? { |m| m.fullfills?(bm) } }
                @base_models |= new_models.to_value_set
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

            # Explicitely selects a given service on the task models required by
            # this task
            #
            # @param [Models::BoundDataService] the data service that should be
            #   selected
            # @raise [ArgumentError] if the provided service is not a service on
            #   a model in self (i.e. not a service of a component model in
            #   {#base_models}
            # @return [Models::BoundDataService] the selected service. If
            #   'service' is a service of a supermodel of a model in {#model},
            #   the resulting BoundDataService is attached to the actual model
            #   in {#model} and this return value is different from 'service'
            def select_service(service)
                srv_component = service.component_model

                if srv_component.respond_to?(:proxied_data_services)
                    if !(srv_component.proxied_data_services - models).empty?
                        raise ArgumentError, "#{service} is not a service of #{self}"
                    end
                    @service = service
                else
                    # Make sure that the service is bound to one of our models
                    component_model = models.find { |m| m.fullfills?(service.component_model) }
                    if !component_model
                        raise ArgumentError, "#{service} is not a service of #{self}"
                    end
                    @service = service.attach(component_model)
                end
            end

            # Removes any service selection
            def unselect_service
                @service = nil
            end

            # Finds a data service by name
            #
            # This only works if there is a single component model in {#models}.
            #
            # @param [String] service_name the service name
            # @return [InstanceRequirements,nil] the requirements with the requested
            #   data service selected or nil if there are no service with the
            #   requested name
            # @raise [ArgumentError] if there are no component models in
            #   {#models}
            def find_data_service(service_name)
                task_model = models.find { |m| m <= Syskit::Component }
                if !task_model
                    raise ArgumentError, "cannot select a service on #{models.map(&:short_name).sort.join(", ")} as there are no component models"
                end
                if service = task_model.find_data_service(service_name)
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
                if service && service.fullfills?(service_type)
                    return self
                end

                candidates = models.find_all do |m|
                    m.fullfills?(service_type)
                end
                if candidates.size > 1
                    raise AmbiguousServiceSelection.new(self, service_type, candidates)
                elsif candidates.empty?
                    return
                end

                model = candidates.first
                if model.respond_to?(:find_data_service_from_type)
                    result = dup
                    result.select_service(model.find_data_service_from_type(service_type))
                    result
                else self
                end
            end

            # Finds the composition's child by name
            #
            # @raise [ArgumentError] if this InstanceRequirements object does
            #   not refer to a composition
            def find_child(name)
                composition_models = models.find_all { |m| m.respond_to?(:find_child) }
                if composition_models.empty?
                    raise ArgumentError, "#{self} is not a composition"
                end
                composition_models.each do |m|
                    if child = m.find_child(name)
                        return child.attach(self)
                    end
                end
            end

            def find_port(name)
                candidates = []
                if service
                    candidates << service.find_port(name)
                end

                models.each do |m|
                    if !service || service.component_model != m
                        candidates << m.find_port(name)
                    end
                end
                if candidates.size > 1
                    raise AmbiguousPortName.new(self, name, candidates)
                end
                if port = candidates.first
                    port.attach(self)
                end
            end

            # Return true if this child provides all of the required models
            def fullfills?(required_models)
                if !required_models.respond_to?(:each)
                    required_models = [required_models]
                end
                if service
                    required_models.all? do |req_m|
                        service.fullfills?(req_m)
                    end
                else
                    required_models.all? do |req_m|
                        models.any? { |m| m.fullfills?(req_m) }
                    end
                end
            end

            # Merges +self+ and +other_spec+ into +self+
            #
            # Throws ArgumentError if the two specifications are not compatible
            # (i.e. can't be merged)
            def merge(other_spec)
                @base_models = Models.merge_model_lists(@base_models, other_spec.base_models)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)
                if service && other_spec.service && service != other_spec.service
                    @service = nil
                elsif !service
                    @service = other_spec.service
                end

                @deployment_hints |= other_spec.deployment_hints
                @dependency_injection_context.concat(other_spec.dependency_injection_context)
                # Call modules that could have been included in the class to
                # extend it
                super if defined? super

                narrow_model
                self
            end

            def hash; base_models.hash end
            def eql?(obj)
                obj.kind_of?(InstanceRequirements) &&
                    obj.selections == selections &&
                    obj.arguments == arguments &&
		    obj.service == service
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
                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    raise ArgumentError, "#use is available only for compositions, got #{base_models.map(&:short_name).join(", ")}"
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

                explicit.each do |child_name, req|
                    if req.respond_to?(:fullfills?) # Might be a string
                        if child = composition_model.find_child(child_name)
                            if !req.fullfills?(child.to_instance_requirements.base_models)
                                raise ArgumentError, "cannot use #{req} as a selection for #{child_name}: incompatible with #{child}"
                            end
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

            # @deprecated
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

            # Use the specified hints to select deployments
            def use_deployments(*patterns)
                @deployment_hints |= patterns.to_set
                self
            end

            # Computes the value of +model+ based on the current selection
            # (in #selections) and the base model specified in #add or
            # #define
            def narrow_model
                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    @models = @base_models
                    return
                elsif composition_model.specializations.empty?
                    @models = @base_models
                    return
                end

                debug do
                    debug "narrowing model"
                    debug "  from #{composition_model.short_name}"
                    break
                end

                context = log_nest(4) do
                    selection = self.selections.dup
                    selection.remove_unresolved
                    DependencyInjectionContext.new(selection)
                end

                result = log_nest(2) do
                    composition_model.narrow(context)
                end

                debug do
                    if result
                        debug "  using #{result.short_name}"
                    end
                    break
                end

                models = base_models.dup
                models.delete_if { |m| result.fullfills?(m) }
                models << result
                @models = models
                return result
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
                task_model = Syskit.proxy_task_model_for(models)
                task = task_model.new(@arguments)
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Returns the taks model that should be used to represent the result
            # of the deployment of this requirement in a plan
            # @return [Model<Roby::Task>]
            def proxy_task_model
                if models.size == 1 && (models.first <= Component)
                    models.first
                else Syskit.proxy_task_model_for(models)
                end
            end

            # Create a concrete task for this requirement
            def instanciate(plan, context = Syskit::DependencyInjectionContext.new, arguments = Hash.new)
                task_model = self.proxy_task_model

                context.save

                # Add a barrier for the names that our models expect. This is
                # required to avoid recursively reusing names (which was once
                # upon a time, and is a very confusing feature)
                barrier = Hash.new
                models.each do |m|
                    m.dependency_injection_names.each do |n|
                        if !selections.has_selection_for?(n)
                            barrier[n] = nil
                        end
                    end
                end
                selections = self.selections
                if !barrier.empty?
                    selections = selections.dup
                    selections.add_explicit(barrier)
                end
                context.concat(dependency_injection_context)
                context.push(selections)

                arguments = Kernel.validate_options arguments, :task_arguments => nil
                instanciate_arguments = { :task_arguments => self.arguments }
                if arguments[:task_arguments]
                    instanciate_arguments[:task_arguments].merge!(arguments[:task_arguments])
                end

                task = task_model.instanciate(plan, context, instanciate_arguments)
                task.requirements.merge(self)
                if !task_model.fullfills?(base_models)
                    raise InternalError, "instanciated task #{task} does not provide the required models #{base_models.map(&:short_name).join(", ")}"
                end

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end

                if service
                    service.bind(task)
                else
                    task
                end

            rescue InstanciationError => e
                e.instanciation_chain << self
                raise
            ensure context.restore
            end

            def each_fullfilled_model(&block)
                if service
                    service.each_fullfilled_model(&block)
                else
                    models.each do |m|
                        m.each_fullfilled_model(&block)
                    end
                end
            end

            def fullfilled_model
                task_model = Component
                tags = []
                each_fullfilled_model do |m|
                    if m <= Roby::Task
                        if m <= task_model
                            task_model = m
                        end
                    elsif m != DataService
                        tags << m
                    end
                end
                [task_model, tags, @arguments.dup]
            end

            def as_plan
                Syskit::InstanceRequirementsTask.subplan(self)
            end

            def to_s
                result =
                    if base_models.size == 1
                        base_models.to_a[0].short_name
                    else
                        "<" + base_models.map(&:short_name).join(",") + ">"
                    end
                if service
                    result << ".#{service.name}_srv"
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
                if base_models.empty?
                    pp.text "No models"
                else
                    pp.text "Base Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(base_models) do |mod|
                            pp.text mod.short_name
                        end
                    end

                    pp.breakable
                    pp.text "Narrowed Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(models) do |mod|
                            pp.text mod.short_name
                        end
                    end
                end

		if service
		    pp.breakable
		    pp.text "Service:"
		    pp.nest(2) do
			pp.breakable
			service.pretty_print(pp)
		    end
		end

                if !selections.empty?
                    pp.breakable
                    pp.text "Using:"
                    pp.nest(2) do
                        pp.breakable
                        selections.pretty_print(pp)
                    end
                end

                if !arguments.empty?
                    pp.breakable
                    pp.text "Arguments: #{arguments}"
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
                    model =
                        if service then service
                        else models.find { |m| m <= Component }.short_name
                        end

                    raise NoMethodError, "#{model.short_name} has no data service called #{service_name}"
                when /^(\w+)_child$/
                    child_name = $1
                    if child = find_child(child_name)
                        return child
                    end
                    raise NoMethodError, "#{models.find { |m| m <= Composition }.short_name} has no child called #{child_name}"
                when /^(\w+)_port$/
                    port_name = $1
                    if port = find_port(port_name)
                        return port
                    end
                    raise NoMethodError, "no port called #{port_name} in any of #{models.map(&:short_name).sort.join(", ")}"
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

            def find_model_by_type(type)
                models.find { |m| m <= type }
            end

            # Tests if these requirements explicitly point to a component model
            def component_model?
                !!find_model_by_type(Syskit::Component)
            end

            # Tests if these requirements explicitly point to a composition model
            def composition_model?
                !!find_model_by_type(Syskit::Composition)
            end

            def period(value)
                dynamics.period(value)
                self
            end

            def bind(object)
                if service then service.bind(object)
                else object
                end
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
        end
end

