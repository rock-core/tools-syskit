module Syskit
        # Generic representation of requirements on a component instance
        #
        # Components can be compositions, services and/or 
        #
        # It is used by compositions to represent the requirements on their
        # children (through the Models::CompositionChild class) and by the
        # Engine to represent instanciation requirements as set by #add or
        # #define (through the EngineRequirement class)
        class InstanceRequirements
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
            # If set, this requirements points to a specific service, not a
            # specific task. Use #select_service to select.
            attr_reader :service

            # The model selection that can be used to instanciate this task,
            # as resolved using names and application of default selections
            #
            # This information is only valid in the instanciation context, i.e.
            # while the underlying engine is instanciating the requirements
            attr_reader :resolved_using_spec

            # A set of hints for deployment disambiguation (as matchers on the
            # deployment names). New hints can be added with #use_deployments
            attr_reader :deployment_hints

            def initialize(models = [])
                @models    = @base_models = models
                @arguments = Hash.new
                @selections = DependencyInjection.new
                @deployment_hints = Set.new
            end

            def initialize_copy(old)
                @models = old.models.dup
                @base_models = old.base_models.dup
                @arguments = old.arguments.dup
                @selections = old.selections.dup
                @deployment_hints = old.deployment_hints.dup
                @service = service
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                new_models = new_models.dup
                new_models.delete_if { |m| @base_models.any? { |bm| bm.fullfills?(m) } }
                base_models.delete_if { |bm| new_models.any? { |m| m.fullfills?(bm) } }
                @base_models |= new_models.to_value_set
                narrow_model
            end

            # Explicitely selects a given service on the task models required by
            # this task
            def select_service(service)
                if service.respond_to?(:to_str) || service.kind_of?(Models::DataServiceModel)
                    task_model = @models.find { |m| m.kind_of?(Syskit::Component) }
                    if !task_model
                        raise ArgumentError, "cannot select a service on #{models.map(&:short_name).sort.join(", ")} as there are no component models"
                    end
                    service_model =
                        if service.respond_to?(:to_str)
                            task_model.find_data_service(service)
                        else
                            task_model.find_data_service_from_type(service)
                        end

                    if !service_model
                        raise ArgumentError, "there is no service called #{service} on #{task_model.short_name}"
                    end
                    @service = service_model
                else
                    @service = service
                end
            end

            def find_data_service(service)
                task_model = @models.find { |m| m.kind_of?(Syskit::ComponentModel) }
                if !task_model
                    raise ArgumentError, "cannot select a service on #{models.map(&:short_name).sort.join(", ")} as there are no component models"
                end
                if service_model = task_model.find_data_service(service)
                    result = dup
                    result.select_service(service)
                    result
                end
            end

            def find_data_service_from_type(service)
                task_model = @models.find { |m| m.kind_of?(Syskit::ComponentModel) }
                if !task_model
                    raise ArgumentError, "cannot select a service on #{models.map(&:short_name).sort.join(", ")} as there are no component models"
                end
                if service_model = task_model.find_data_service_from_type(service)
                    result = dup
                    result.select_service(service)
                    result
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

            # Merges two lists of models into a single one.
            #
            # The resulting list can only have a single class object. Modules
            # that are already included in these classes get removed from the
            # list as well
            #
            # Raises if +a+ and +b+ contain two classes that can't be mixed.
            def self.merge_model_lists(a, b)
                a_classes, a_modules = a.partition { |k| k.kind_of?(Class) }
                b_classes, b_modules = b.partition { |k| k.kind_of?(Class) }

                klass = a_classes.first || b_classes.first
                a_classes.concat(b_classes).each do |k|
                    if k < klass
                        klass = k
                    elsif !(klass <= k)
                        raise ArgumentError, "cannot merge #{a} and #{b}: classes #{k} and #{klass} are not compatible"
                    end
                end

                result = ValueSet.new
                result << klass if klass
                a_modules.concat(b_modules).each do |m|
                    do_include = true
                    result.delete_if do |other_m|
                        do_include &&= !(other_m <= m)
                        m < other_m
                    end
                    if do_include
                        result << m
                    end
                end
                result
            end

            # Merges +self+ and +other_spec+ into +self+
            #
            # Throws ArgumentError if the two specifications are not compatible
            # (i.e. can't be merged)
            def merge(other_spec)
                @base_models = InstanceRequirements.merge_model_lists(@base_models, other_spec.base_models)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)
                if service && other_spec.service && service != other_spec.service
                    @service = nil
                else
                    @service = other_spec.service
                end

                @deployment_hints |= other_spec.deployment_hints
                # Call modules that could have been included in the class to
                # extend it
                super if defined? super

                narrow_model
            end

            def hash; base_models.hash end
            def eql?(obj)
                obj.kind_of?(InstanceRequirements) &&
                    obj.selections == selections &&
                    obj.arguments == arguments &&
                    (super if defined? super)
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
                Engine.debug "adding use mappings #{mappings} to #{self}"

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

                explicit, defaults = DependencyInjection.validate_use_argument(*mappings)
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
            end

            # Add a new model in the base_models set, and update +models+
            # accordingly
            #
            # This method will keep the base_models consistent: +model+ is added
            # only if it is not yet provided in base_models, and any model in
            # +base_models+ that is also provided by +model+ will be removed.
            #
            # Returns true if +model+ did add a new constraint to the
            # specification, and false otherwise
            def require_model(model)
                if !model.kind_of?(Module) && !model.kind_of?(Class)
                    raise ArgumentError, "expected module or class, got #{model} of class #{model.class}"
                end
                need_model = true
                base_models.delete_if do |m|
                    if model < m
                        true
                    elsif m <= model
                        need_model = false
                        false
                    end
                end

                if need_model
                    base_models << model
                    narrow_model
                    return true
                else
                    return false
                end
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

                Engine.debug do
                    Engine.debug "narrowing model"
                    Engine.debug "  from #{composition_model.short_name}"
                    break
                end

                context = Engine.log_nest(4) do
                    selection = self.selections.dup
                    selection.remove_unresolved
                    DependencyInjectionContext.new(selection)
                end

                result = Engine.log_nest(2) do
                    composition_model.narrow(context)
                end

                Engine.debug do
                    if result
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

            def instanciation_model
                task_model = models.find { |m| m <= Roby::Task }
                if task_model && models.size == 1
                    return task_model
                else 
                    return Syskit.proxy_task_model_for(models)
                end
            end

            # Returns a task that can be used in the plan as a placeholder for
            # this instance
            def create_placeholder_task
                task_model = instanciation_model
                task = task_model.new(@arguments)
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Create a concrete task for this requirement
            def instanciate(engine, context, arguments = Hash.new)
                task_model = instanciation_model

                context.push(selections)

                arguments = Kernel.validate_options arguments, :task_arguments => nil
                instanciate_arguments = {
                    :as => name,
                    :task_arguments => self.arguments }
                if arguments[:task_arguments]
                    instanciate_arguments[:task_arguments].merge!(arguments[:task_arguments])
                end

                @task = task_model.instanciate(engine, context, instanciate_arguments)
                task.requirements.merge(self)
                if !task_model.fullfills?(base_models)
                    raise InternalError, "instanciated task #{@task} does not provide the required models #{base_models.map(&:short_name).join(", ")}"
                end

                if models.size > 1
                    task.abstract = true
                end

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end

                if service
                    service.bind(task)
                else
                    @task
                end

            rescue InstanciationError => e
                e.instanciation_chain << self
                raise
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
                        value.service.bind(value.task)
                    else
                        value.service
                    end
                        
                when EngineRequirement, Models::BoundDataService, Roby::Task, CompositionChild
                    value
                when Class
                    if value <= Component
                        value
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                when BoundDataService
                    return value
                else
                    if value.respond_to?(:to_ary)
                        value.map { |v| resolve_explicit_selection(v, engine) }
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                end
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
                    if m.kind_of?(Roby::Task)
                        task_model = m
                    else
                        tags << m
                    end
                end
                [task_model, tags, @arguments.dup]
            end

            def as_plan
                Syskit::SingleRequirementTask.subplan(self)
            end

            def to_s
                if base_models.empty?
                    result = "#<#{self.class}: <no models>"
                else
                    result = "#<#{self.class}: models=#{models.map(&:short_name).join(",")} base=#{base_models.map(&:short_name).join(",")}"
                end
                if !selections.empty?
                    result << " using(#{selections})"
                end
                if !arguments.empty?
                    result << " args(#{arguments})"
                end
                if service
                    result << " srv=#{service}"
                end
                result << ">"
            end

            def pretty_print(pp)
                if base_models.empty?
                    pp.breakable
                    pp.text "No models"
                else
                    pp.breakable
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

                super if defined? super
            end

            def find_child(name)
                composition = models.find { |m| m <= Composition }
                if !composition
                    raise ArgumentError, "this requirement object does not refer to a composition explicitely, cannot select a child"
                end
                composition.send("#{name}_child")
            end

            def method_missing(method, *args)
                if !args.empty? || block_given?
                    return super
                end

		case method.to_s
                when /^(\w+)_srv$/
                    service_name = $1
                    task_model = models.find { |m| m <= Component }
                    if !task_model
                        raise ArgumentError, "this requirement object does not refer to a task context explicitely, cannot select a service"
                    end
                    if service
                        service_name = "#{service.name}.#{service_name}"
                    end
                    srv = task_model.find_data_service(service_name)
                    if !srv
                        raise ArgumentError, "the task model #{task_model.short_name} does not have any service called #{service_name}, known services are: #{task_model.each_data_service.map(&:last).map(&:name).join(", ")}"
                    end

                    result = self.dup
                    result.select_service(srv)
                    return result
                when /^(\w+)_child$/
                    child_name = $1
                    composition = models.find { |m| m <= Composition }
                    if !composition
                        raise ArgumentError, "this requirement object does not refer to a composition explicitely, cannot select a child"
                    end
                    child = composition.send(method)
                    return child.attach(self)
                when /^(\w+)_port$/
                    port_name = $1
                    if service
                        port_name = service.port_mappings_for_task[port_name] || port_name
                    end
                    component = models.find { |m| m <= Component }
                    if !component
                        raise ArgumentError, "this requirement object does not refer to a component explicitely, cannot select a port"
                    end
                    port = component.send("#{port_name}_port")
                    return port.dup.attach(self)
                end
                super(method.to_sym, *args)
            end
        end

end

