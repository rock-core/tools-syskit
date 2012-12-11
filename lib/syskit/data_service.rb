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

            # Returns the device object that is attached to the given service.
            #
            # @param [BoundDataService,String,nil] service the service for which
            #   we want the attached device. It can be omitted in the (very
            #   common) case of tasks that are driving only one device
            # @return [MasterDeviceInstance,nil] the device object, or nil if
            #   there is no device attached to the required service
            # @raise [ArgumentError] if the provided service name does not
            #   exist, or if it is nil and this task context drives more than
            #   one device.
            def find_device_attached_to(service = nil)
                if service
                    if service.respond_to?(:to_str)
                        if !(service = find_data_service(service))
                            raise ArgumentError, "#{service} is not a known service of #{self}, known services are: #{each_data_service.map(&:name).sort.join(', ')}"
                        end
                    end
                else
                    driver_services = model.each_master_driver_service.to_a
                    if driver_services.empty?
                        raise ArgumentError, "#{self} is not attached to any device"
                    elsif driver_services.size > 1
                        raise ArgumentError, "#{self} handles more than one device, you must specify one of #{driver_services.map(&:name).sort.join(", ")} explicitely"
                    end
                    service = driver_services.first
                end

                device_name = arguments["#{service.name}_name"]
                if device_name
                    if !(device = robot.devices[device_name])
                        raise SpecError, "#{self} attaches device #{device_name} to #{service.full_name}, but #{device_name} is not a known device"
                    end
                    device
                end
            end

            # Alias for #find_device_attached_to for user code
            #
            # (see #find_device_attached_to)
            def robot_device(subname = nil)
                find_device_attached_to(subname)
            end

            # Enumerates the MasterDeviceInstance objects associated with this
            # task context
            #
            # It yields the data service and the device model
            #
            # @yields [MasterDeviceInstance]
            # @see #each_device
            def each_master_device
                if !block_given?
                    return enum_for(:each_master_device)
                end

                seen = Set.new
                model.each_master_driver_service do |srv|
                    if (device = find_device_attached_to(srv)) && !seen.include?(device.name)
                        yield(device)
                        seen << device.name
                    end
                end
            end
        end

        ComBus = Models::ComBusModel.new
        Models::ComBusModel.base_module = ComBus

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBus
            include Device

            # Enumerates all the devices that are attached to this communication bus
            #
            # @yieldparam device [DeviceInstance] a device that is using self as
            #   a communication bus
            attribute(:port_to_device) { Hash.new { |h, k| h[k] = Array.new } }

            def merge(merged_task)
                super
                port_to_device.merge!(merged_task.port_to_device)
            end

            def each_attached_device(&block)
                each_master_device do |combus|
                    next if !combus.model.kind_of?(ComBusModel)

                    robot.each_master_device do |name, dev|
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
