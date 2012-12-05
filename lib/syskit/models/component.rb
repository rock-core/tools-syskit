module Syskit
    module Models
        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module Component
            include Models::Base
            include Syskit::DataService

            # Method that maps data services from this component's parent models
            # to this composition's own
            #
            # It is called as needed when calling {#each_data_service}
            def promote_data_service(full_name, service)
                service.attach(self)
            end

            # The data services defined on this task, as a mapping from the data
            # service full name to the BoundDataService object.
            #
            # @key_name full_name
            # @return [Hash<String,BoundDataService>]
            define_inherited_enumerable(:data_service, :data_services, :map => true) { Hash.new }

            # Enumerates all the device models this component is a driver for
            #
            # @yields [Model<Device>]
            # @return [void]
            def each_device(&block)
                each_data_service.find_all { |_, srv| srv.model < Device }.
                    each(&block)
            end

            # Generic data service selection method, based on a service type
            # and an optional service name. It implements the following
            # algorithm:
            #  
            #  * only services that match +target_model+ are considered
            #  * if there is only one service of that type and no pattern is
            #    given, that service is returned
            #  * if there is a pattern given, it must be either the service
            #    full name or its subname (for slaves)
            #  * if an ambiguity is found between root and slave data
            #    services, and there is only one root data service matching,
            #    that data service is returned.
            def find_matching_service(target_model, pattern = nil)
                # Find services in +child_model+ that match the type
                # specification
                matching_services = find_all_services_from_type(target_model)

                if pattern # match by name too
                    # Find the selected service. There can be shortcuts, so
                    # for instance bla.left would be able to select both the
                    # 'left' main service or the 'bla.blo.left' slave
                    # service.
                    rx = /(^|\.)#{pattern}$/
                    matching_services.delete_if { |service| service.full_name !~ rx }
                end

                if matching_services.size > 1
                    main_matching_services = matching_services.
                        find_all { |service| service.master? }

                    if main_matching_services.size != 1
                        raise AmbiguousServiceSelection.new(self, target_model, main_matching_services), "there is more than one service of type #{target_model.name} in #{self.name}#{" matching name hint #{pattern}" if pattern}"
                    end
                    selected = main_matching_services.first
                else
                    selected = matching_services.first
                end

                selected
            end

            # Enumerates all services that are slave (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_slave_data_service(master_service)
                return enum_for(:each_slave_data_service, master_service) if !block_given?
                each_data_service(nil) do |name, service|
                    if service.master && (service.master.full_name == master_service.full_name)
                        yield(service)
                    end
                end
            end

            # Enumerates all services that are root (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_root_data_service(&block)
                return enum_for(:each_root_data_service, master_service) if !block_given?
                each_data_service(nil) do |name, service|
                    if service.master?
                        yield(service)
                    end
                end
            end

            # Generic instanciation of a component. 
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the engine's plan and returns it.
            def instanciate(engine, context = DependencyInjectionContext.new, arguments = Hash.new)
                task_arguments, instanciate_arguments = Kernel.
                    filter_options arguments, :task_arguments => Hash.new
                engine.plan.add(task = new(task_arguments[:task_arguments]))
                task
            end

            # The model next in the ancestry chain, or nil if +self+ is root
            def supermodel
                if superclass.respond_to?(:register_submodel)
                    return superclass
                end
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
                srv = find_data_service_from_type(service_model)
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

            # Finds a single service that provides +type+
            #
            # @see #find_all_data_services_from_type
            #
            # @param [Model<DataService>] type the data service type
            # @return [Models::BoundDataService,nil] the data service found, or
            #   nil if none can be found with the specified type
            # @raise AmbiguousServiceSelection if multiple services exist with
            #   that type
            def find_data_service_from_type(type)
                candidates = find_all_data_services_from_type(type)
                if candidates.size > 1
                    raise AmbiguousServiceSelection.new(self, type, candidates),
                        "multiple services match #{type.short_name} on #{short_name}"
                elsif candidates.size == 1
                    return candidates.first
                end
            end

            # Finds a single service that provides +type+
            #
            # @see #find_data_service_from_type
            #
            # @param [Model<DataService>] type the data service type
            # @return [Array<Models::BoundDataService>] the list of data
            #   services that match the given type
            def find_all_data_services_from_type(type)
                result = []
                each_data_service do |_, m|
                    result << m if m.fullfills?(type)
                end
                result
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

            PROVIDES_ARGUMENTS = { :as => nil, :slave_of => nil }

            # Declares that this component provides the given data service.
            # +model+ can either be the data service constant name (from
            # Syskit::DataServices), or its plain name.
            #
            # If the data service defines an interface, the component must
            # provide the required input and output ports. If an ambiguity
            # exists, explicit port mappings must be provided.
            #
            # @param [Hash] arguments option hash, as well as explicit port
            #   mappings. The values that are not reserved options (listed
            #   below) are used as port mappings, of the form:
            #      component_port_name => service_port_name
            #   I.e. they specify that service_port_name on the service should
            #   be mapped to component_port_name on the component
            # @option arguments [String] :as the name of the service. If it is
            #   not given, the basename of the model name converted to snake case
            #   is used, e.g. ImageProvider becomes image_provider.
            # @option arguments [String] :slave_of the name of another data
            #   service, of which this service should be a slave.
            #
            # @raise ArgumentError if a data service with that name already
            #   exists
            # @raise SpecError if the new data service overrides a data service
            #   from the parent, but does not provide the service from this
            #   parent. See example below.
            #
            # @example Invalid service overriding. This is an error if Service2
            #   does not provide Service1
            #
            #   class TaskModel < Component
            #     provides Service, :as => 'service'
            #   end
            #   class SubTaskModel < TaskModel
            #     provides Service2, :as => 'service2'
            #   end
            #
            def provides(model, arguments = Hash.new)
                source_arguments, arguments = Kernel.filter_options arguments,
                    :as => nil,
                    :slave_of => nil

                name =
                    if !source_arguments[:as]
                        if !model.name
                            raise ArgumentError, "no service name given, and the model has no name"
                        end
                        model.name.gsub(/^.+::/, '').snakecase
                    else source_arguments[:as]
                    end
                full_name = name

                if master_source = source_arguments[:slave_of]
                    master = find_data_service(master_source)
                    if !master
                        raise ArgumentError, "master data service #{master_source} is not registered on #{self}"
                    end
                    full_name = "#{master.full_name}.#{name}"
                end

                # Get the source name and the source model
                if data_services[full_name]
                    raise ArgumentError, "there is already a data service named '#{name}' defined on '#{self.name}'"
                end

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                if has_data_service?(full_name)
                    parent_type = find_data_service(full_name).model
                    if !(model <= parent_type)
                        raise ArgumentError, "#{self} has a data service named #{full_name} of type #{parent_type}, which is not a parent type of #{model}"
                    end
                end

                if master && (master.component_model != self)
                    data_services[master.full_name] = master.attach(self)
                end

                service = BoundDataService.new(name, self, master, model, Hash.new)

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

                include model

                data_services[full_name] = service

                Models.debug do
                    Models.debug "#{short_name} provides #{model.short_name}"
                    Models.debug "port mappings"
                    service.port_mappings.each do |m, mappings|
                        Models.debug "  #{m.short_name}: #{mappings}"
                    end
                    break
                end

                arguments.each do |key, value|
                    send("#{key}=", value)
                end
                return service
            end

            def method_missing(m, *args)
                if m == :orogen_model
                    raise NoMethodError, "tried to use a method to access an oroGen model, but none exists on #{self}"
                end
                if args.empty? && !block_given?
                    if m.to_s =~ /^(\w+)_srv$/
                        service_name = $1
                        if service_model = find_data_service(service_name)
                            return service_model
                        else
                            raise NoMethodError, "#{short_name} has no service called #{service_name}"
                        end
                    end
                end
                super
            end

            # :attr: private_specialization?
            #
            # If true, this model is used internally as specialization of
            # another component model (as e.g. to represent dynamic service
            # instantiation). Otherwise, it is an actual component model.
            attr_predicate :private_specialization?, true

            # Creates a private specialization of the current model
            def specialize(name = nil)
                klass = new_submodel
                if name
                    klass.name = name
                end
                klass.private_specialization = true
                klass.private_model
                klass
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
            def as_plan
                Syskit::SingleRequirementTask.subplan(self)
            end

            def resolve(component)
                if !component.kind_of?(self)
                    raise TypeError, "cannot resolve #{self} into #{component}"
                end
                component
            end
        end
    end
end

