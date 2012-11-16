module Syskit
    module Models
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

            # A port attached to a component
            class Port
                # A data source for a port attached to a component
                class DataSource
                    attr_reader :task
                    attr_reader :reader

                    def initialize(task, *port_spec)
                        @task = task
                        task.execute do
                            @reader = task.data_reader(*port_spec)
                        end
                    end

                    def read
                        reader.read if reader
                    end
                end

                # [ComponentModel] The component model this port is part of
                attr_reader :component_model
                # [Orocos::Spec::Port] The port model
                attr_reader :model
                # [String] The port name on +component_model+. It can be
                # different from model.name, as the port could be imported from
                # another component
                attr_accessor :name

                def initialize(component_model, model, name = model.name)
                    @component_model, @name, @model =
                        component_model, name, model
                end

                def same_port?(other)
                    other.kind_of?(Port) && other.component_model == component_model &&
                        other.model == model
                end

                def ==(other) # :nodoc:
                    other.kind_of?(Port) && other.component_model == component_model &&
                    other.model == model &&
                    other.name == name
                end

                # This is needed to use the Port to represent a data
                # source on the component's state as e.g.
                #
                #   state.position = Component.pose_samples
                #
                def to_state_variable_model(field, name)
                    model = Roby::StateVariableModel.new(field, name)
                    model.type = type
                    model.data_source = self
                    model
                end

                # Returns a DataSource that represents this port
                #
                # @arg context either an Engine or a task instance. If it is an
                #              engine, the method adds a new instance of the
                #              right model and returns the corresponding
                #              DataSource. Otherwise, simply returns the
                #              DataSource for the given task.
                def resolve(context)
                    if context.kind_of?(Roby::Plan)
                        context.add(context = component_model.as_plan)
                    end
                    context = context.as_service
                    if !context.respond_to?(:data_reader)
                        raise ArgumentError, "cannot get a data reader from #{context}"
                    end
                    DataSource.new(context, name)
                end

                # Returns the true name for the port, i.e. the name of the port on
                # the child
                def actual_name; model.name end

                # Change the component model
                def rebind(model)
                    @component_model = model
                    self
                end

		def type
		    model.type
		end

                def respond_to?(m, *args)
                    super || model.respond_to?(m, *args)
                end

                def method_missing(*args, &block)
                    model.send(*args, &block)
                end
            end

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
            # only then call #as on the returned BoundDataService object
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
            # Syskit::DataServices), or its plain name.
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
                        # slaves by using the service's BoundDataService
                        # object
                        master = master.overload(self)
                        data_services[master.full_name] = master
                    end
                end

                include model

                service = BoundDataService.new(name, self, master, model, Hash.new)
                full_name = service.full_name
                # TODO: make compute_port_mappings work on the component_model /
                # service_model instead of on a Models::BoundDataService. We should
                # not create the Models::BoundDataService until we know that it can
                # be created

                begin
                    new_port_mappings = compute_port_mappings(service, arguments)
                    service.port_mappings[model] = new_port_mappings

                    # Now, adapt the port mappings from +model+ itself and map
                    # them into +service.port_mappings+
                    Models.update_port_mappings(service.port_mappings, new_port_mappings, model.port_mappings)

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

                debug do
                    debug "#{short_name} provides #{model.short_name}"
                    debug "port mappings"
                    service.port_mappings.each do |m, mappings|
                        debug "  #{m.short_name}: #{mappings}"
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
                    if port = self.find_port(m.to_s)
                        return Port.new(self, port)
                    elsif service = self.find_data_service(m.to_s)
                        return service
                    elsif m.to_s =~ /^(\w+)_port$/
                        port_name = $1
                        if port = find_input_port(port_name)
                            return Port.new(self, port)
                        elsif port = find_output_port(port_name)
                            return Port.new(self, port)
                        elsif port = self.find_port(port_name)
                            return Port.new(self, port)
                        else
                            raise NoMethodError, "#{self} has no port called #{port_name}"
                        end
                    elsif m.to_s =~ /^(\w+)_srv$/
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
        end
    end
end

