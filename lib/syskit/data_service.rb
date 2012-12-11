module Syskit
        DataService = Models::DataServiceModel.new
        Models::DataServiceModel.base_module = DataService
        module DataService
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
        end

        Device   = Models::DeviceModel.new
        Models::DeviceModel.base_module = Device

        # Modelling and instance-level functionality for devices
        #
        # Devices are, in Syskit plugin, the tools that allow to
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
                    each_root_data_service.each do |srv|
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
