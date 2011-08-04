module Orocos
    module RobyPlugin
        # Class that is used to represent a binding of a service model with an
        # actual task instance during the instanciation process
        class DataServiceInstance
            # The ProvidedDataService instance that represents the data service
            attr_reader :provided_service_model
            # The task instance we are bound to
            attr_reader :task

            def initialize(task, provided_service_model)
                @task, @provided_service_model = task, provided_service_model
                if !task.kind_of?(Component)
                    raise "expected a task instance, got #{task}"
                end
                if !provided_service_model.kind_of?(ProvidedDataService)
                    raise "expected a provided service, got #{provided_service_model}"
                end
            end

            def short_name
                "#{task}:#{provided_service_model.name}"
            end

	    def each_fullfilled_model(&block)
		provided_service_model.component_model.each_fullfilled_model(&block)
	    end

            def fullfills?(*args)
                provided_service_model.fullfills?(*args)
            end
        end

        # Generic representation of requirements on a component instance
        #
        # Components can be compositions, services and/or 
        #
        # It is used by compositions to represent the requirements on their
        # children (through the CompositionChildDefinition class) and by the
        # Engine to represent instanciation requirements as set by #add or
        # #define (through the EngineRequirement class)
        class ComponentInstance
            # The Engine instance
            attr_reader :engine
            # The component model narrowed down from +base_models+ using
            # +using_spec+
            attr_reader :models
            # The component model specified by #add
            attr_reader :base_models
            # Required arguments on the final task
            attr_reader :arguments
            # The actual selection given to Engine#add
            attr_reader :using_spec

            def initialize(engine, models)
                @engine    = engine
                @models    = @base_models = models
                @arguments = Hash.new
                @using_spec = Hash.new
            end

            def initialize_copy(old)
                @models = old.models.dup
                @base_models = old.base_models.dup
                @arguments = old.arguments.dup
                @using_spec = old.using_spec.dup
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                new_models = new_models.dup
                new_models.delete_if { |m| @base_models.any? { |bm| bm.fullfills?(m) } }
                base_models.delete_if { |bm| new_models.any? { |m| m.fullfills?(bm) } }
                @base_models |= new_models.to_value_set
                narrow_model
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

                mappings = RobyPlugin.validate_using_spec(*mappings)
                using_spec.merge!(mappings)

                narrow_model
                self
            end

            # Specifies new arguments that must be set to the instanciated task
            def with_arguments(arguments)
                @arguments.merge!(arguments)
                self
            end

            # Specifies that the task that is represented by this requirement
            # should use the given configuration
            def use_conf(*conf)
                @arguments[:conf] = conf
                self
            end

            # Computes the value of +model+ based on the current selection
            # (in using_spec) and the base model specified in #add or
            # #define
            def narrow_model
                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    Engine.debug "not narrowing as this selection is not a composition"
                    @models = @base_models
                    return
                end

                Engine.debug do
                    Engine.debug "narrowing model"
                    Engine.debug "  from #{composition_model.short_name}"
                    break
                end

                selection = Hash.new
                begin
                    using_spec.each_key do |key|
                        if result = self.class.resolve_explicit_selection(using_spec[key], engine)
                            selection[key] = result
                        end
                    end
                    if engine
                        engine.add_default_selections(selection)
                    end
                rescue ArgumentError => e
                    Engine.debug { "not narrowing as some of the selections can only be resolved at runtime: #{e.message}" }
                    return
                end

                candidates = composition_model.narrow(selection)
                result =
                    if candidates.size == 1
                        candidates.find { true }
                    else
                        composition_model
                    end

                Engine.debug do
                    if candidates.size > 1
                        Engine.debug "  found multiple candidates, using default model #{result.short_name}"
                    else
                        Engine.debug "  using #{result.short_name}"
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
            # this instance
            def create_placeholder_task
                task_model = models.find { |m| m <= Roby::Task }
                if task_model
                    task = task_model.new(@arguments)
                else 
                    if !@task_model || @task_model.fullfilled_model[1].to_set != models.to_set
                        @task_model = DataServiceModel.proxy_task_model(models)
                    end
                    task = @task_model.new(@arguments)
                end
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Create a concrete task for this requirement
            def instanciate(engine, arguments = Hash.new)
                if self.engine && self.engine != engine
                    raise ArgumentError, "cannot instanciate on a different engine that the one set"
                end

                task_model = models.find { |m| m < Component }
                if !task_model
                    raise ArgumentError, "cannot call #instanciate on a composite model"
                end

                result = self.class.resolve_explicit_selections(using_spec, engine)
                result = engine.add_default_selections(result)

                arguments = Kernel.validate_options arguments, :task_arguments => nil
                instanciate_arguments = {
                    :as => name,
                    :selection => result,
                    :task_arguments => self.arguments }
                if arguments[:task_arguments]
                    instanciate_arguments[:task_arguments].merge!(arguments[:task_arguments])
                end

                @task = task_model.instanciate(engine, instanciate_arguments)
                if !task_model.fullfills?(base_models)
                    raise InternalError, "instanciated task #{@task} does not provide the required models #{base_models.map(&:short_name).join(", ")}"
                end

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end

                @task
            end

            def self.resolve_explicit_selections(using_spec, engine = nil)
                result = Hash.new
                using_spec.each do |key, selected|
                    if resolved_selection = resolve_explicit_selection(selected, engine)
                        result[key] = resolved_selection
                    end
                end

                result = resolve_default_selections(result)
                resolve_recursive_selection(result)
            end

            # This method checks if there are default selections (which are
            # saved as nil => [selection_list]. If there are some, they get
            # mapped to service => selection entries
            def self.resolve_default_selections(using_spec)
                default_selections = using_spec[nil]
                if !default_selections
                    return using_spec
                end

                Engine.debug do
                    Engine.debug "resolving default selections"
                    default_selections.each do |sel|
                        Engine.debug "  #{sel}"
                    end
                    break
                end

                result = using_spec.dup
                result.delete(nil)

                ambiguous_default_selections = ValueSet.new
                resolved_default_selections = Hash.new

                default_selections.each do |selection|
                    selection.each_fullfilled_model do |m|
                        if using_spec[m]
                            Engine.debug do
                                Engine.debug "  rejected #{selection} for #{m}: already explicitely selected"
                                break
                            end
                        elsif ambiguous_default_selections.include?(m)
                            Engine.debug do
                                Engine.debug "  rejected #{selection} for #{m}: ambiguous"
                                break
                            end
                        elsif resolved_default_selections[m]
                            ambiguous_default_selections << m
                            removed = resolved_default_selections.delete(m)
                            Engine.debug do
                                Engine.debug "  rejected #{removed} for #{m}: ambiguous"
                                Engine.debug "  rejected #{selection} for #{m}: ambiguous"
                                break
                            end
                        elsif selection != m
                            resolved_default_selections[m] = selection
                        end
                    end
                end
                Engine.debug do
                    resolved_default_selections.each do |key, sel|
                        Engine.debug "  #{key.respond_to?(:short_name) ? key.short_name : key}: #{sel}"
                    end
                    break
                end
                result.merge!(resolved_default_selections)
            end

            def self.resolve_using_spec(using_spec)
                result = Hash.new
                using_spec.each do |key, value|
                    if value.respond_to?(:to_ary)
                        result[key] = value.map do |v|
                            yield(key, v)
                        end.compact
                    elsif filtered = yield(key, value)
                        result[key] = filtered
                    end
                end
                result
            end

            # Resolves a selection given through the #use method
            #
            # It can take, as input, one of:
            # 
            # * an array, in which case it is called recursively on each of
            #   the array's elements.
            # * an EngineRequirement (returned by Engine#add)
            # * a name
            #
            # In the latter case, the name refers either to a device name,
            # or to the name given through the ':as' argument to Engine#add.
            # A particular service can also be selected by adding
            # ".service_name" to the component name.
            #
            # The returned value is either an array of resolved selections,
            # a Component instance or an InstanciatedDataService instance.
            def self.resolve_explicit_selection(value, engine)
                case value
                when DeviceInstance
                    if value.task
                        DataServiceInstance.new(value.task, value.service)
                    else
                        value.service
                    end
                        
                when EngineRequirement, ProvidedDataService, Roby::Task, CompositionChild
                    value
                when Class
                    if value <= Component
                        value
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                when DataServiceInstance
                    return value
                else
                    if value.respond_to?(:to_ary)
                        value.map { |v| resolve_explicit_selection(v, engine) }
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                end
            end

            def self.resolve_recursive_selection(using_spec)
                result = Hash.new
                using_spec.each do |key, value|
                    result[key] = resolve_single_recursive_selection(value, using_spec)
                end
                result
            end

            def self.resolve_single_recursive_selection(value, using_spec)
                resolved_value = value
                while (new_value = using_spec[resolved_value])
                    resolved_value = new_value
                end
                resolved_value
            end

            def each_fullfilled_model(&block)
                models.each do |m|
                    m.each_fullfilled_model(&block)
                end
            end

            def as_plan
                Orocos::RobyPlugin::SingleRequirementTask.subplan(self)
            end

            def to_s
                result = "#<#{self.class}: #{models.map(&:short_name).join(", ")}"
                if using_spec
                    result << " using(#{using_spec})"
                end
                result << ">"
            end

        end

    end
end

