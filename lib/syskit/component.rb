module Orocos
    module RobyPlugin
        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module ComponentModel
            include Model

            ##
            # :method: each_data_service
            # :call-seq:
            #     each_data_service { |service_name, service| }
            #
            # Enumerates all the data services that are provided by this
            # component model, as pairs of source name and DataService instances.
            # Unlike #data_services, it enumerates both the sources added at
            # this level of the model hierarchy and the ones that are provided
            # by the model's parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ##
            # :method: find_data_service
            # :call-seq:
            #   find_data_service(name) -> service
            #
            # Returns the DataService instance that has the given name, or nil if
            # there is none.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ## :attr_reader: data_services
            #
            # The data services that are provided by this particular component
            # model, as a hash mapping the source name to the corresponding
            # DataService instance. This only includes new sources that have been
            # added at this level of the component hierarchy, not the ones that
            # have already been added to the model parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            # Returns the port object that maps to the given name, or nil if it
            # does not exist.
            def find_port(name)
                name = name.to_str
                find_output_port(name) || find_input_port(name)
            end

            def has_port?(name)
                has_input_port?(name) || has_output_port?(name)
            end

            # Returns the output port with the given name, or nil if it does not
            # exist.
            def find_output_port(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.find_output_port(name)
            end

            # Returns the input port with the given name, or nil if it does not
            # exist.
            def find_input_port(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.find_input_port(name)
            end

            # Enumerates this component's output ports
            def each_output_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_output_port(&block)
            end

            # Enumerates this component's input ports
            def each_input_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_input_port(&block)
            end

            # Enumerates all of this component's ports
            def each_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_port(&block)
            end

            # Returns true if +name+ is a valid output port name for instances
            # of +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_output_port?(name, including_dynamic = true)
                return true if find_output_port(name)
                if including_dynamic
                    has_dynamic_output_port?(name)
                end
            end

            # Returns true if +name+ is a valid input port name for instances of
            # +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_input_port?(name, including_dynamic = true)
                return true if find_input_port(name)
                if including_dynamic
                    has_dynamic_input_port?(name)
                end
            end

            # True if +name+ could be a dynamic output port name.
            #
            # Dynamic output ports are declared on the task models using the
            # #dynamic_output_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_output_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic output port declarations using this predicate.
            def has_dynamic_output_port?(name, type = nil)
                return if !respond_to?(:orogen_spec)
                orogen_spec.has_dynamic_output_port?(name, type)
            end

            # True if +name+ could be a dynamic input port name.
            #
            # Dynamic input ports are declared on the task models using the
            # #dynamic_input_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_input_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic input port declarations using this predicate.
            def has_dynamic_input_port?(name, type = nil)
                return if !respond_to?(:orogen_spec)
                orogen_spec.has_dynamic_input_port?(name, type)
            end

            # Generic instanciation of a component. 
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the engine's plan and returns it.
            def instanciate(engine, context, arguments = Hash.new)
                task_arguments, instanciate_arguments = Kernel.
                    filter_options arguments, :task_arguments => Hash.new
                engine.plan.add(task = new(task_arguments[:task_arguments]))
                task.robot = engine.robot
                task
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.with_arguments('special_behaviour' => true))
            #
            def with_arguments(*spec, &block)
                Engine.create_instanciated_component(nil, nil, self).with_arguments(*spec, &block)
            end

            # @deprecated
            def use_conf(*spec, &block)
                with_conf(*spec, &block)
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.use_conf('special_conf'))
            #
            def with_conf(*spec, &block)
                Engine.create_instanciated_component(nil, nil, self).with_conf(*spec, &block)
            end

            # Returns a view of this component as a producer of the given model
            #
            # This will fail if multiple services offer +service_model+. In this
            # case, one would have to first explicitely select the service and
            # only then call #as on the returned ProvidedDataService object
            def as(service_model)
                srv = find_service_from_type(service_model)
                return srv.as(service_model)
            end

	    # Defined to be compatible, in port mapping code, with the data services
	    def port_mappings_for_task
	    	Hash.new { |h,k| k }
	    end

            # Helper method for compute_port_mappings
            def compute_directional_port_mappings(result, service, direction, explicit_mappings) # :nodoc:
                remaining = service.model.send("each_#{direction}_port").to_a

                used_ports = service.component_model.
                    send("each_data_service").
                    find_all { |_, task_service| task_service.model == service.model }.
                    inject(Set.new) { |used_ports, (_, task_service)| used_ports |= task_service.port_mappings.values.to_set }

                # 0. check if an explicit port mapping is provided for this port
                remaining.delete_if do |port|
                    mapping = explicit_mappings[port.name]
                    next if !mapping

                    # Verify that the mapping is valid
                    component_port = service.component_model.
                        send("find_#{direction}_port", mapping)
                    if !component_port
                        raise InvalidPortMapping, "the explicit mapping from #{port.name} to #{mapping} is invalid as #{mapping} is not an #{direction} port of #{service.component_model.name}"
                    end
                    if component_port.type != port.type
                        raise InvalidPortMapping, "the explicit mapping from #{port.name} to #{mapping} is invalid as they have different types (#{port.type_name} != #{component_port.type_name}"
                    end
                    result[port.name] = mapping
                end

                # 1. check if the task model has a port with the same name and
                #    same type
                remaining.delete_if do |port|
                    component_port = service.component_model.
                        send("find_#{direction}_port", port.name)
                    if component_port && component_port.type == port.type
                        used_ports << component_port.name
                        result[port.name] = port.name
                    end
                end

                while !remaining.empty?
                    current_size = remaining.size
                    remaining.delete_if do |port|
                        # 2. look at all ports that have the same type
                        candidates = service.component_model.send("each_#{direction}_port").
                            find_all { |p| !used_ports.include?(p.name) && p.type == port.type }
                        if candidates.empty?
                            raise InvalidPortMapping, "no candidate to map #{direction} port #{port.name}[#{port.type_name}] from #{service.name} onto #{short_name}"
                        elsif candidates.size == 1
                            used_ports << candidates.first.name
                            result[port.name] = candidates.first.name
                            next(true)
                        end

                        # 3. try to filter the ambiguity by name
                        name_rx = Regexp.new(service.name)
                        by_name = candidates.find_all { |p| p.name =~ name_rx }
                        if by_name.empty?
                            raise InvalidPortMapping, "#{candidates.map(&:name)} are equally valid candidates to map #{port.name}[#{port.type_name}] from the '#{service.name}' service onto the #{short_name} task's interface"
                        elsif by_name.size == 1
                            used_ports << by_name.first.name
                            result[port.name] = by_name.first.name
                            next(true)
                        end

                        # 3. try full name if the service is a slave service
                        next if service.master?
                        name_rx = Regexp.new(service.master.name)
                        by_name = by_name.find_all { |p| p.name =~ name_rx }
                        if by_name.size == 1
                            used_ports << by_name.first.name
                            result[port.name] = by_name.first.name
                            next(true)
                        end
                    end

                    if remaining.size == current_size
                        port = remaining.first
                        raise InvalidPortMapping, "there are multiple candidates to map #{port.name}[#{port.type_name}] from #{service.name} onto #{name}"
                    end
                end
            end

            # @return [InstanceRequirements] this component model with the
            # required service selected
            def select_service(service)
                result = InstanceRequirements.new([self])
                result.select_service(service)
                result
            end

            def find_service_from_type(type)
                find_data_service_from_type(type)
            end

            # Finds a single service that provides +type+
            #
            # If multiple services exist with that signature, raises
            # AmbiguousServiceSelection
            def find_data_service_from_type(type)
                candidates = find_all_services_from_type(type)
                if candidates.size > 1
                    raise AmbiguousServiceSelection.new(self, type, candidates),
                        "multiple services match #{type.short_name} on #{short_name}"
                elsif candidates.size == 1
                    return candidates.first
                end
            end

            def find_all_services_from_type(type)
                find_all_data_services_from_type(type)
            end

            # Finds all the services that fullfill the given service type
            def find_all_data_services_from_type(type)
                result = []
                each_data_service do |_, m|
                    result << m if m.fullfills?(type)
                end
                result
            end

            # Returns the port mappings that are required by the usage of this
            # component as a service of type +service_type+
            #
            # If no name are given, the method will raise
            # AmbiguousServiceSelection if there are multiple services of the
            # given type
            def port_mappings_for(service_type)
                if service_type.kind_of?(DataServiceModel)
                    service = find_service_from_type(service_type)
                    if !service
                        raise ArgumentError, "#{short_name} does not provide a service of type #{service_type.short_name}"
                    end
                else
                    service, service_type = service_type, service_type.model
                end

                service.port_mappings_for(service_type).dup
            end

            # Compute the port mapping from the interface of 'service' onto the
            # ports of 'self'
            #
            # The returned hash is
            #
            #   service_interface_port_name => task_model_port_name
            #
            def compute_port_mappings(service, explicit_mappings = Hash.new)
                normalized_mappings = Hash.new
                explicit_mappings.each do |from, to|
                    from = from.to_s if from.kind_of?(Symbol)
                    to   = to.to_s   if to.kind_of?(Symbol)
                    if from.respond_to?(:to_str) && to.respond_to?(:to_str)
                        normalized_mappings[from] = to 
                    end
                end

                result = Hash.new
                compute_directional_port_mappings(result, service, "input", normalized_mappings)
                compute_directional_port_mappings(result, service, "output", normalized_mappings)
                result
            end

            DATA_SERVICE_ARGUMENTS = { :as => nil, :slave_of => nil, :config_type => nil }

            # Declares that this component provides the given data service.
            # +model+ can either be the data service constant name (from
            # Orocos::RobyPlugin::DataServices), or its plain name.
            #
            # If the data service defines an interface, the component must
            # provide the required input and output ports, *matching the port
            # name*. See the discussion about the 'main' argument for port name
            # matching.
            #
            # The following arguments are accepted:
            #
            # as::
            #   the data service name on this task context. By default, it
            #   will be derived from the model name by converting it to snake
            #   case (i.e. stereo_camera for StereoCamera)
            # slave_of::
            #   creates a data service that is slave from another data service.
            #
            def provides(model, arguments = Hash.new)
                source_arguments, arguments = Kernel.filter_options arguments,
                    DATA_SERVICE_ARGUMENTS

                model = Model.validate_service_model(model, system_model, DataService)

                # Get the source name and the source model
                name = (source_arguments[:as] || model.name.gsub(/^.+::/, '').snakecase).to_str
                if data_services[name]
                    raise ArgumentError, "there is already a source named '#{name}' defined on '#{self.name}'"
                end

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                if has_data_service?(name)
                    parent_type = find_data_service(name).model
                    if !(model <= parent_type)
                        raise SpecError, "#{self} has a data service named #{name} of type #{parent_type}, which is not a parent type of #{model}"
                    end
                end

                if master_source = source_arguments[:slave_of]
                    if !has_data_service?(master_source.to_str)
                        raise SpecError, "master source #{master_source} is not registered on #{self}"
                    end
                    master = find_data_service(master_source)
                    if master.component_model != self
                        # Need to create an overload at this level of the
                        # hierarchy, or one will not be able to enumerate the
                        # slaves by using the service's ProvidedDataService
                        # object
                        master = master.overload(self)
                        data_services[master.full_name] = master
                    end
                end

                include model

                service = ProvidedDataService.new(name, self, master, model, Hash.new)
                full_name = service.full_name
                # TODO: make compute_port_mappings work on the component_model /
                # service_model instead of on a ProvidedDataService. We should
                # not create the ProvidedDataService until we know that it can
                # be created

                begin
                    new_port_mappings = compute_port_mappings(service, arguments)
                    service.port_mappings[model] = new_port_mappings

                    # Now, adapt the port mappings from +model+ itself and map
                    # them into +service.port_mappings+
                    SystemModel.update_port_mappings(service.port_mappings, new_port_mappings, model.port_mappings)

                    # Remove from +arguments+ the items that were port mappings
                    new_port_mappings.each do |from, to|
                        if arguments[from].to_s == to # this was a port mapping !
                            arguments.delete(from)
                        elsif arguments[from.to_sym].to_s == to
                            arguments.delete(from.to_sym)
                        end
                    end
                rescue InvalidPortMapping => e
                    raise InvalidProvides.new(self, model, e), "#{short_name} does not provide the '#{model.name}' service's interface. #{e.message}", e.backtrace
                end

                data_services[full_name] = service

                SystemModel.debug do
                    SystemModel.debug "#{short_name} provides #{model.short_name}"
                    SystemModel.debug "port mappings"
                    service.port_mappings.each do |m, mappings|
                        SystemModel.debug "  #{m.short_name}: #{mappings}"
                    end
                    break
                end

                arguments.each do |key, value|
                    send("#{key}=", value)
                end
                return service
            end

            def method_missing(m, *args)
                if args.empty? && !block_given?
                    if m.to_s =~ /^(\w+)_port/
                        port_name = $1
                        if port = find_input_port(port_name)
                            return port
                        elsif port = find_output_port(port_name)
                            return port
                        elsif port = self.find_port(m.to_s)
                            return port
                        else
                            raise NoMethodError, "#{self} has no port called #{port_name}"
                        end
                    elsif m.to_s =~ /^(\w+)_srv/
                        service_name = $1
                        if service_model = find_data_service(service_name)
                            return service_model
                        else
                            raise NoMethodError, "#{self} has no service called #{service_name}"
                        end
                    elsif port = self.find_port(m.to_s)
                        return port
                    elsif service = self.find_data_service(m.to_s)
                        return service
                    end
                end
                super
            end
        end

        # Base class for models that represent components (TaskContext,
        # Composition)
        #
        # The model-level methods (a.k.a. singleton methods) are defined on
        # ComponentModel). See the documentation of Model for an explanation of
        # this.
        #
        # Components may be data service providers. Two types of data sources
        # exist:
        # * main services are root data services that can be provided
        #   independently
        # * slave sources are data services that depend on another service. For
        #   instance, an ImageProvider source of a StereoCamera task could be
        #   slave of the main PointCloudProvider source.
        #
        # Data services are referred to by name. In the case of a main service,
        # its name is the name used during the declaration. In the case of slave
        # services, it is main_data_service_name.slave_name. I.e. the name of
        # the slave service depends on the selected 
        class Component < ::Roby::Task
            extend ComponentModel

            def inspect; to_s end

            # The Robot instance we are running on
            attr_accessor :robot

            # The name of the process server that should run this component
            #
            # On regular task contexts, it is the host on which the task is
            # required to run. On compositions, it affects the composition's
            # children
            attr_accessor :required_host

            # The InstanceRequirements object for which this component has been
            # instanciated.
            attr_reader :requirements

            # Returns the set of communication busses names that this task
            # needs.
            def com_busses
                result = Set.new
                arguments.find_all do |arg_name, bus_name| 
                    if arg_name.to_s =~ /_com_bus$/
                        result << bus_name
                    end
                end
                result
            end

            def initialize(options = Hash.new)
                super
                @reusable = true
                @requirements = InstanceRequirements.new
            end

            def create_fresh_copy
                new_task = super
                new_task.robot = robot
                new_task
            end

            def reusable?
                super && @reusable
            end

            def do_not_reuse
                @reusable = false
            end

            # Returns a set of hints that should be used to disambiguate the
            # deployment of this task.
            #
            # It looks for #deployment_hints in the requirements. If there are
            # none, it then looks in the parents.
            def deployment_hints
                hints = requirements.deployment_hints
                return hints if !hints.empty?

                result = Set.new
                each_parent_task do |p|
                    result |= p.deployment_hints
                end
                result
            end

            # Returns a placeholder task that can be used to require that a
            # task from this component model is deployed and started at a
            # certain point in the plan.
            #
            # It is usually used implicitely with the plan and relation methods directly:
            #
            #   cmp = task.depends_on(Cmp::MyComposition)
            #
            # calls this method behind the scenes.
            def self.as_plan
                Orocos::RobyPlugin::SingleRequirementTask.subplan(self)
            end

            # Returns the set of models this model fullfills
            def self.each_fullfilled_model
                ancestors.each do |m|
                    if m <= Component || m <= DataService
                        yield(m)
                    end
                end
            end

            # Returns the set of models this task fullfills
            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            # This is documented on ComponentModel
            inherited_enumerable(:data_service, :data_services, :map => true) { Hash.new }

            attribute(:instanciated_dynamic_outputs) { Hash.new }
            attribute(:instanciated_dynamic_inputs) { Hash.new }

            # Returns the output port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def find_output_port_model(name)
                if port_model = model.orogen_spec.find_output_port(name)
                    port_model
                else instanciated_dynamic_outputs[name]
                end
            end

            # Returns the input port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def find_input_port_model(name)
                if port_model = model.orogen_spec.find_input_port(name)
                    port_model
                else instanciated_dynamic_inputs[name]
                end
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_input(name, type = nil)
                if port = instanciated_dynamic_inputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_input_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_inputs[name] = port
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_output(name, type = nil)
                if port = instanciated_dynamic_outputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_output_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_outputs[name] = port
            end

            # Return the device instance name that is tied to the given provided
            # data service
            #
            # +data_service+ is a ProvidedDataService instance, i.e. a value
            # returned by e.g. Component.find_data_service, or the name of a
            # service declared on this component. This service should be a
            # device model. The value returned by this function is then the
            # name of the robot's device which is tied to this service
            def selected_device(data_service)
                if data_service.respond_to?(:to_str)
                    data_service = model.find_data_service(data_service)
                end

                if data_service.master
                    parent_service_name = selected_device(data_service.master)
                    "#{parent_service_name}.#{data_service.name}"
                else
                    arguments["#{data_service.name}_name"]
                end
            end

            # Returns the data service model for the given service name
            #
            # Raises ArgumentError if service_name is not the name of a data
            # service name declared on this component model.
            def data_service_type(service_name)
                service_name = service_name.to_str
                root_service_name = service_name.gsub /\..*$/, ''
                root_source = model.each_root_data_service.find do |name, source|
                    arguments[:"#{name}_name"] == root_service_name
                end

                if !root_source
                    raise ArgumentError, "there is no source named #{root_service_name}"
                end
                if root_service_name == service_name
                    return root_source.last.model
                end

                subname = service_name.gsub /^#{root_service_name}\./, ''

                model = self.model.data_service_type("#{root_source.first}.#{subname}")
                if !model
                    raise ArgumentError, "#{subname} is not a slave source of #{root_service_name} (#{root_source.first}) in #{self.model.name}"
                end
                model
            end

            # Returns true if the underlying Orocos task is in a state that
            # allows it to be configured
            def ready_for_setup? # :nodoc:
                true
            end

            # Returns true if the underlying Orocos task has been properly
            # configured
            attr_predicate :setup?, true

            # Call to configure the component. User-provided configuration calls
            # should be defined in a #configure method
            #
            # Note that for error-handling reasons, the setup? flag is not set
            # by this method. Caller must call is_setup! after a successful call
            # to #setup
            def setup
                configure
            end

            # User-provided part of the component configuration
            def configure
                super if defined? super
            end

            def user_required_model
                if model.respond_to?(:proxied_data_services)
                    model.proxied_data_services
                else
                    [model]
                end
            end

            def can_merge?(target_task)
                if !(super_result = super)
                    NetworkMergeSolver.debug { "cannot merge #{target_task} into #{self}: super returned false" }
                    return super_result
                end

                # The orocos bindings are a special case: if +target_task+ is
                # abstract, it means that it is a proxy task for data
                # source/device drivers model
                #
                # In that particular case, the only thing the automatic merging
                # can do is replace +target_task+ iff +self+ fullfills all tags
                # that target_task has (without considering target_task itself).
                models = user_required_model
                if !fullfills?(models)
                    NetworkMergeSolver.debug { "cannot merge #{target_task} into #{self}: does not fullfill required model #{models.map(&:name).join(", ")}" }
                    return false
                end

                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                self_inputs = Hash.new { |h, k| h[k] = Hash.new }
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    self_inputs[sink_port][[source_task, source_port]] = policy
                end

                might_be_cycle = false
                target_task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if (port_model = model.find_input_port(sink_port)) && port_model.multiplexes?
                        next
                    end

                    # If +self+ has no connection on +sink_port+, it is valid
                    if !self_inputs.has_key?(sink_port)
                        next
                    end

                    # If the exact same connection is provided, verify that
                    # the policies match
                    if conn_policy = self_inputs[sink_port][[source_task, source_port]]
                        if !policy.empty? && (RobyPlugin.update_connection_policy(conn_policy, policy) != policy)
                            NetworkMergeSolver.debug { "cannot merge #{target_task} into #{self}: incompatible policies on #{sink_port}" }
                            return false
                        end
                        next
                    end

                    # Otherwise, we look for potential cycles, i.e. for
                    # connections where:
                    #
                    #  * the port names are the same
                    #  * the tasks are different
                    #  * but the tasks are interlinked
                    #
                    # If there seem to be a cycle, return a "maybe".
                    # Otherwise, return false
                    found = false
                    self_inputs[sink_port].each do |conn, conn_policy|
                        next if conn[1] != source_port

                        if Flows::DataFlow.reachable?(self, conn[0]) && Flows::DataFlow.reachable?(target_task, source_task)
                            if RobyPlugin.update_connection_policy(conn_policy, policy) == policy
                                found = true
                            end
                        end
                    end

                    if found
                        might_be_cycle = true
                    else
                        NetworkMergeSolver.debug do
                            NetworkMergeSolver.debug "cannot merge #{target_task} into #{self}: incompatible connections on #{sink_port}, resp."
                            NetworkMergeSolver.debug "    #{source_task}.#{source_port}"
                            NetworkMergeSolver.debug "    --"
                            self_inputs[sink_port].each_key do |conn|
                                NetworkMergeSolver.debug "    #{conn[0]}.#{conn[1]}"
                            end
                            break
                        end
                        return false
                    end
                end

                if might_be_cycle
                    return nil # undecided
                else
                    return true
                end
            end

            def merge(merged_task)
                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each_static do |key, value|
                    arguments[key] = value if !arguments.set?(key)
                end

                # Instanciate missing dynamic ports
                self.instanciated_dynamic_outputs =
                    merged_task.instanciated_dynamic_outputs.merge(instanciated_dynamic_outputs)
                self.instanciated_dynamic_inputs =
                    merged_task.instanciated_dynamic_inputs.merge(instanciated_dynamic_inputs)

                # Merge the fullfilled model if set explicitely
                # TODO: have proper accessors
                # TODO: change API for merge_fullfilled_model
                # TODO: make fullfilled_model always manipulate [task_model,
                # tags, arguments] instead of mixed representations
                explicit_merged_fullfilled_model = merged_task.instance_variable_get(:@fullfilled_model)
                explicit_this_fullfilled_model = @fullfilled_model
                if explicit_this_fullfilled_model && explicit_merged_fullfilled_model
                    self.fullfilled_model = Roby::TaskStructure::Dependency.merge_fullfilled_model(
                        explicit_merged_fullfilled_model,
                        [explicit_this_fullfilled_model[0]] + explicit_this_fullfilled_model[1],
                        explicit_this_fullfilled_model[2])

                elsif explicit_merged_fullfilled_model
                    self.fullfilled_model = explicit_merged_fullfilled_model.dup
                end

                # Merge the InstanceRequirements objects
                requirements.merge(merged_task.requirements)

                # Call included plugins if there are some
                super if defined? super

                # Finally, remove +merged_task+ from the data flow graph and use
                # #replace_task to replace it completely
                plan.replace_task(merged_task, self)
                nil
            end

            # The set of data readers created with #data_reader. Used to disconnect
            # them when the task stops
            attribute(:data_readers) { Array.new }

            # The set of data writers created with #data_writer. Used to disconnect
            # them when the task stops
            attribute(:data_writers) { Array.new }

            # Common implementation of port search for #data_reader and
            # #data_writer
            def data_accessor(*args) # :nodoc:
                policy = Hash.new
                if args.last.respond_to?(:to_hash)
                    policy = args.pop
                end

                port_name = args.pop
                if !args.empty?
                    role_path = args
                    parent = resolve_role_path(role_path[0..-2])
                    task   = parent.child_from_role(role_path.last)
                    if parent.respond_to?(:map_child_port)
                        port_name = parent.map_child_port(role_path.last, port_name)
                    end
                else
                    task = self
                end

                return task, port_name, policy
            end

            # call-seq:
            #   data_writer 'port_name'[, policy]
            #   data_writer 'role_name', 'port_name'[, policy]
            #
            # Returns a data writer that allows to read the specified port
            #
            # In the first case, the returned writer is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_writer('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The writer is automatically disconnected when the task quits
            def data_writer(*args)
                task, port_name, policy = data_accessor(*args)

                port = task.find_input_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no input port #{port_name}"
                end

                result = port.writer(policy)
                data_writers << result
                result
            end

            # call-seq:
            #   data_reader 'port_name'[, policy]
            #   data_reader 'role_name', 'port_name'[, policy]
            #
            # Returns a data reader that allows to read the specified port
            #
            # In the first case, the returned reader is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_reader('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The reader is automatically disconnected when the task quits
            def data_reader(*args)
                task, port_name, policy = data_accessor(*args)
                policy, other_policy = Kernel.filter_options policy, :pull => true
                policy.merge!(other_policy)

                port = task.find_output_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no output port #{port_name}"
                end

                result = port.reader(policy)
                data_readers << result
                result
            end

            on :stop do |event|
                data_writers.each do |writer|
                    if writer.connected?
                        writer.disconnect
                    end
                end
                data_readers.each do |reader|
                    if reader.connected?
                        reader.disconnect
                    end
                end
            end

            def to_component; self end

            def find_data_service(service_name)
                if service_model = model.find_data_service(service_name)
                    return service_model.bind(self)
                end
            end

            def method_missing(m, *args)
                if args.empty? && !block_given?
                    if m.to_s =~ /^(\w+)_port/
                        port_name = $1
                        if port = find_input_port(port_name)
                            return port
                        elsif port = find_output_port(port_name)
                            return port
                        else
                            raise NoMethodError, "#{self} has no port called #{port_name}"
                        end
                    elsif m.to_s =~ /^(\w+)_srv/
                        service_name = $1
                        if service_model = find_data_service(service_name)
                            return service_model
                        else
                            raise NoMethodError, "#{self} has no service called #{service_name}"
                        end
                    end
                end
                super
            end

            # Returns a view of this component as a provider of the given
            # service model. It can for instance be used to connect ports while
            # transparently applying port mappings
            #
            # It works only if there is only one service providing the requested
            # type on +self+. Otherwise, one will have to select the service
            # first and only then call #as on the DataServiceInstance object
            #
            # The same can be done at the model level with ComponentModel#as
            def as(service_model)
                return model.as(service_model).bind(self)
            end
        end
    end
end

