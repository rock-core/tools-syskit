module Syskit
        DataService = Models::DataServiceModel.new
        Models::DataServiceModel.base_module = DataService
        module DataService
            module ClassExtension
                def find_data_services(&block)
                    each_data_service.find_all(&block)
                end

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
                            raise Ambiguous, "there is more than one service of type #{target_model.name} in #{self.name}: #{matching_services.map(&:name).join(", ")}); you must select one explicitely with a 'use' statement"
                        end
                        selected = main_matching_services.first
                    else
                        selected = matching_services.first
                    end

                    selected
                end

                # call-seq:
                #   TaskModel.each_slave_data_service do |name, service|
                #   end
                #
                # Enumerates all services that are slave (i.e. not slave of other
                # services)
                def each_slave_data_service(master_service, &block)
                    each_data_service(nil).
                        find_all { |name, service| service.master == master_service }.
                        map { |name, service| [service.name, service] }.
                        each(&block)
                end


                # call-seq:
                #   TaskModel.each_root_data_service do |name, source_model|
                #   end
                #
                # Enumerates all services that are root (i.e. not slave of other
                # services)
                def each_root_data_service(&block)
                    each_data_service(nil).
                        find_all { |name, srv| srv.master? }.
                        each(&block)
                end
            end

            extend ClassExtension

            # Returns true if +self+ can replace +target_task+ in the plan. The
            # super() call checks graph-declared dependencies (i.e. that all
            # dependencies that +target_task+ meets are also met by +self+.
            #
            # This method checks that +target_task+ and +self+ do not represent
            # two different data services
            def can_merge?(target_task)
                if !(super_result = super)
                    NetworkMergeSolver.debug { "cannot merge #{target_task} into #{self}: super returned false" }
                    return super_result
                end
                if !target_task.kind_of?(DataService)
                    NetworkMergeSolver.debug { "cannot merge #{target_task} into #{self}: #{target_task} has no services" }
                    return false
                end

                # Check that for each data service in +target_task+, we can
                # allocate a corresponding service in +self+
                each_service_merge_candidate(target_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        NetworkMergeSolver.debug do
                            NetworkMergeSolver.debug "cannot merge #{target_task} into #{self} as"
                            NetworkMergeSolver.debug "  no candidates for #{other_service}"
                            break
                        end

                        return false
                    elsif self_services.size > 1
                        NetworkMergeSolver.debug do
                            NetworkMergeSolver.debug "cannot merge #{target_task} into #{self} as"
                            NetworkMergeSolver.debug "  ambiguous service selection for #{other_service}"
                            NetworkMergeSolver.debug "  candidates:"
                            self_services.map(&:to_s).each do |name|
                                NetworkMergeSolver.debug "    #{name}"
                            end
                            break
                        end
                        return false
                    end
                end
                true
            end

            # Replace +merged_task+ by +self+, possibly modifying +self+ so that
            # it is possible.
            def merge(merged_task)
                connection_mappings = Hash.new

                # First thing to do is reassign data services from the merged
                # task into ourselves. Note that we do that only for services
                # that are actually in use.
                each_service_merge_candidate(merged_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        raise SpecError, "trying to merge #{merged_task} into #{self}, but that seems to not be possible"
                    elsif self_services.size > 1
                        raise AmbiguousImplicitServiceSelection.new(self, merged_task, other_service, self_services), "merging #{self} and #{merged_task} is ambiguous: the #{self_services.map(&:short_name).join(", ")} data services could be used"
                    end

                    # "select" one service to use to handle other_name
                    target_service = self_services.pop
                    # set the argument
                    if selected_source_name && arguments["#{target_service.name}_name"] != selected_source_name
                        arguments["#{target_service.name}_name"] = selected_source_name
                    end

                    # What we also need to do is map port names from the ports
                    # in +merged_task+ into the ports in +self+. We do that by
                    # moving the connections explicitely from +merged_task+ onto
                    # +self+
                    merged_service_to_task = other_service.port_mappings_for_task.dup
                    target_to_task         = target_service.port_mappings_for(other_service.model)

                    NetworkMergeSolver.debug do
                        NetworkMergeSolver.debug "      mapping service #{merged_task}:#{other_service.name}"
                        NetworkMergeSolver.debug "        to #{self}:#{target_service.name}"
                        NetworkMergeSolver.debug "        from->from_task: #{merged_service_to_task}"
                        NetworkMergeSolver.debug "        from->to_task:   #{target_to_task}"
                        break
                    end

                    target_to_task.each do |from, to|
                        from = merged_service_to_task.delete(from) || from
                        connection_mappings[from] = to
                    end
                    merged_service_to_task.each do |from, to|
                        connection_mappings[to] = from
                    end
                end

                # We have to move the connections in two steps
                #
                # We first compute the set of connections that have to be
                # created on the final task, applying the port mappings to the
                # existing connections on +merged_tasks+
                #
                # Then we remove all connections from +merged_task+ and merge
                # the rest of the relations (calling super)
                #
                # Finally, we create the new connections
                #
                # This is needed as we can't forward ports between a task that
                # is *not* part of a composition and this composition. We
                # therefore have to merge the Dependency relation before we
                # create the forwardings

                # The set of connections that need to be recreated at the end of
                # the method
                moved_connections = Array.new

                merged_task.each_source do |source_task|
                    connections = source_task[merged_task, Flows::DataFlow]

                    new_connections = Hash.new
                    connections.each do |(from, to), policy|
                        to = connection_mappings[to] || to
                        new_connections[[from, to]] = policy
                    end
                    NetworkMergeSolver.debug do
                        NetworkMergeSolver.debug "      moving input connections of #{merged_task}"
                        NetworkMergeSolver.debug "        => #{source_task} onto #{self}"
                        NetworkMergeSolver.debug "        mappings: #{connection_mappings}"
                        NetworkMergeSolver.debug "        old:"
                        connections.each do |(from, to), policy|
                            NetworkMergeSolver.debug "          #{from} => #{to} (#{policy})"
                        end
                        NetworkMergeSolver.debug "        new:"
                        new_connections.each do |(from, to), policy|
                            NetworkMergeSolver.debug "          #{from} => #{to} (#{policy})"
                        end
                        break
                    end

                    moved_connections << [source_task, self, new_connections]
                end

                merged_task.each_sink do |sink_task, connections|
                    new_connections = Hash.new
                    connections.each do |(from, to), policy|
                        from = connection_mappings[from] || from
                        new_connections[[from, to]] = policy
                    end

                    NetworkMergeSolver.debug do
                        NetworkMergeSolver.debug "      moving output connections of #{merged_task}"
                        NetworkMergeSolver.debug "        => #{sink_task}"
                        NetworkMergeSolver.debug "        onto #{self}"
                        NetworkMergeSolver.debug "        mappings: #{connection_mappings}"
                        NetworkMergeSolver.debug "        old:"
                        connections.each do |(from, to), policy|
                            NetworkMergeSolver.debug "          #{from} => #{to} (#{policy})"
                        end
                        NetworkMergeSolver.debug "        new:"
                        new_connections.each do |(from, to), policy|
                            NetworkMergeSolver.debug "          #{from} => #{to} (#{policy})"
                        end
                        break
                    end

                    moved_connections << [self, sink_task, new_connections]
                end
                Flows::DataFlow.remove(merged_task)

                super

                moved_connections.each do |source_task, sink_task, mappings|
                    source_task.connect_or_forward_ports(sink_task, mappings)
                end
            end

            # Returns true if at least one port of the given service (designated
            # by its name) is connected to something.
            def using_data_service?(source_name)
                service = model.find_data_service(source_name)
                inputs  = service.each_task_input_port.map(&:name)
                outputs = service.each_task_output_port.map(&:name)

                each_source do |output|
                    description = output[self, Flows::DataFlow]
                    if description.any? { |(_, to), _| inputs.include?(to) }
                        return true
                    end
                end
                each_sink do |input, description|
                    if description.any? { |(from, _), _| outputs.include?(from) }
                        return true
                    end
                end
                false
            end

            # Finds the services on +other_task+ that have been selected Yields
            # it along with a data source on +self+ in which it can be merged,
            # either because the source is assigned as well to the same device,
            # or because it is not assigned yet
            def each_service_merge_candidate(other_task) # :nodoc:
                other_task.model.each_root_data_service do |name, other_service|
                    other_selection = other_task.selected_device(other_service)

                    self_selection = nil
                    available_services = []
                    model.each_data_service.find_all do |self_name, self_service|
                        self_selection = selected_device(self_service)
                        is_candidate = self_service.model.fullfills?(other_service.model) &&
                            (!self_selection || !other_selection || self_selection == other_selection)
                        if is_candidate
                            available_services << self_service
                        end
                    end

                    yield(other_selection, other_service, available_services)
                end
            end
        end

        Device   = Models::DeviceModel.new
        Models::DeviceModel.base_module = Device

        # Modelling and instance-level functionality for devices
        #
        # Devices are, in the Orocos/Roby plugin, the tools that allow to
        # represent the inputs and outputs of your component network, i.e. the
        # components that are tied to "something" (usually hardware) that is
        # not represented in the component network.
        #
        # New devices can either be created with
        # device_model.new_submodel if the source should not be registered in
        # the system model, or SystemModel#device_type if it should be
        # registered
        module Device
            include DataService

            # This module is defined on Device objects to define new methods
            # on the classes that provide these devices
            #
            # I.e. for instance, when one does
            #
            #   class OroGenProject::Task
            #     driver_for 'Devices::DeviceType'
            #   end
            #
            # then the methods defined in this module are available on
            # OroGenProject::Task:
            #
            #   OroGenProject::Task.each_master_device
            #
            module ClassExtension
                # Enumerate all the devices that are defined on this
                # component model
                def each_master_device(&block)
                    result = []
                    each_root_data_service.each do |_, srv|
                        if srv.model < Device
                            result << srv
                        end
                    end
                    result.each(&block)
                end
            end

            # Enumerates the devices that are mapped to this component
            #
            # It yields the data service and the device model
            def each_device_name
                if !block_given?
                    return enum_for(:each_device_name)
                end

                seen = Set.new
                model.each_master_device do |srv|
                    # Slave devices have the same name than the master device,
                    # so no need to list them
                    next if !srv.master?

                    device_name = arguments["#{srv.name}_name"]
                    if device_name && !seen.include?(device_name)
                        seen << device_name
                        yield(srv, device_name)
                    end
                end
            end

            # Enumerates the MasterDeviceInstance and/or SlaveDeviceInstance
            # objects that are mapped to this task context
            #
            # It yields the data service and the device model
            #
            # See also #each_device_name
            def each_device
                if !block_given?
                    return enum_for(:each_device)
                end

                each_master_device do |srv, device|
                    yield(srv, device)

                    device.each_slave do |_, slave|
                        yield(slave.service, slave)
                    end
                end
            end

            # Enumerates the MasterDeviceInstance objects associated with this
            # task context
            #
            # It yields the data service and the device model
            #
            # See also #each_device_name
            def each_master_device
                if !block_given?
                    return enum_for(:each_master_device)
                end

                each_device_name do |service, device_name|
                    if !(device = robot.devices[device_name])
                        raise SpecError, "#{self} attaches device #{device_name} to #{service.full_name}, but #{device_name} is not a known device"
                    end

                    yield(service, device)
                end
            end

            # Enumerates the devices that are slaves to the service called
            # +master_service_name+
            def each_slave_device(master_service_name, expected_device_model = nil) # :yield:slave_service_name, slave_device
                srv = model.find_data_service(master_service_name)
                if !srv
                    raise ArgumentError, "#{model.short_name} has no service called #{master_service_name}"
                end

                master_device_name = arguments["#{srv.name}_name"]
                if master_device_name
                    if !(master_device = robot.devices[master_device_name])
                        raise SpecError, "#{self} attaches device #{device_name} to #{service.full_name}, but #{device_name} is not a known device"
                    end

                    master_device.each_slave do |slave_name, slave_device|
                        if !expected_device_model || slave_device.device_model.fullfills?(expected_device_model)
                            yield("#{srv.name}.#{slave_name}", slave_device)
                        end
                    end
                end
            end

            # Returns either the MasterDeviceInstance or SlaveDeviceInstance
            # that represents the device tied to this component.
            #
            # If +subname+ is given, it has to be the corresponding data service
            # name. It is optional only if there is only one device attached to
            # this component
            def robot_device(subname = nil)
                devices = each_master_device.to_a
                if !subname
                    if devices.empty?
                        raise ArgumentError, "#{self} is not attached to any device"
                    elsif devices.size > 1
                        raise ArgumentError, "#{self} handles more than one device, you must specify one explicitely"
                    end
                else
                    devices = devices.find_all { |srv, _| srv.full_name == subname }
                    if devices.empty?
                        raise ArgumentError, "there is no data service called #{subname} on #{self}"
                    end
                end
                service, device_instance = devices.first
                device_instance
            end
        end

        ComBus = Models::ComBusModel.new
        Models::ComBusModel.base_module = ComBus

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBus
            include Device

            attribute(:port_to_device) { Hash.new { |h, k| h[k] = Array.new } }

            def merge(merged_task)
                super
                port_to_device.merge!(merged_task.port_to_device)
            end

            def each_attached_device(&block)
                model.each_device do |name, ds|
                    next if !ds.model.kind_of?(ComBusModel)

                    combus = robot.devices[arguments["#{ds.name}_name"]]
                    robot.devices.each_value do |dev|
                        # Only master devices can be attached to a bus
                        next if !dev.kind_of?(MasterDeviceInstance)

                        if dev.attached_to?(combus)
                            yield(dev)
                        end
                    end
                end
            end

            def each_device_connection_helper(port_name) # :nodoc:
                return if !port_to_device.has_key?(port_name)

                devices = port_to_device[port_name].
                    map do |d_name|
                        if !(device = robot.devices[d_name])
                            raise ArgumentError, "#{self} refers to device #{d_name} for port #{source_port}, but there is no such device"
                        end
                        device
                    end

                if !devices.empty?
                    yield(port_name, devices)
                end
            end

            # Finds out what output port serves what devices by looking at what
            # tasks it is connected.
            #
            # Indeed, for communication busses, the device model is determined
            # by the sink port of output connections.
            def each_device_connection(&block)
                if !block_given?
                    return enum_for(:each_device_connection)
                end

                each_concrete_input_connection do |source_task, source_port, sink_port|
                    each_device_connection_helper(sink_port, &block)
                end
                each_concrete_output_connection do |source_port, sink_port, sink_task|
                    each_device_connection_helper(source_port, &block)
                end
            end
        end
end
