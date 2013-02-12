module Syskit
        DataService = Models::DataServiceModel.new
        DataService.root = true
        DataService.provides Roby::TaskService
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
        Device.root = true
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

            def each_master_driver_service
                model.each_master_driver_service do |srv|
                    yield(srv.bind(self))
                end
            end

            # Returns the bound data service that is attached to the given
            # device
            def find_all_driver_services_for(device)
                if device.respond_to?(:master_device)
                    find_all_driver_services_for(device.master_device).map do |driver_srv|
                        driver_srv.find_data_service(device.name)
                    end
                else
                    services = model.each_master_driver_service.find_all do |driver_srv|
                        find_device_attached_to(driver_srv) == device
                    end
                    services.map { |drv| drv.bind(self) }
                end
            end

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

                arguments["#{service.name}_dev"]
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
        ComBus.root = true
        Models::ComBusModel.base_module = ComBus

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBus
            include Device

            # Enumerates the communication busses this task is a driver for
            #
            # @yieldparam [Robot::ComBus] the communication bus device
            # @yieldreturn [void]
            # @return [void]
            def each_com_bus_device
                return enum_for(:each_com_bus_device) if !block_given?
                each_master_device do |device|
                    yield(device) if device.kind_of?(Robot::ComBus)
                end
            end

            # Enumerates all the devices that are attached to this communication bus
            #
            # @yieldparam device [DeviceInstance] a device that is using self as
            #   a communication bus
            def each_attached_device
                return enum_for(:each_attached_device) if !block_given?
                each_com_bus_device do |combus|
                    combus.each_attached_device do |dev|
                        yield(dev)
                    end
                end
            end

            # Attaches the given task to the communication bus
            def attach(task)
                model.each_com_bus_driver_service do |combus_srv|
                    # Do we have a device for this bus ?
                    next if !(combus = find_device_attached_to(combus_srv))
                    task.each_master_device do |dev|
                        next if !dev.attached_to?(combus)
                        client_in_srv  = dev.combus_in_srv
                        client_out_srv = dev.combus_out_srv

                        if client_in_srv && client_out_srv
                            bus_srv = require_dynamic_service(combus_srv.model.dynamic_service_name, :as => dev.name, :direction => 'inout')
                            bus_srv.connect_to client_in_srv.bind(task)
                            client_out_srv.bind(task).connect_to bus_srv
                        elsif client_in_srv
                            bus_out_srv = require_dynamic_service(combus_srv.model.dynamic_service_name, :as => dev.name, :direction => 'out')
                            bus_out_srv.connect_to client_in_srv.bind(task)
                        elsif client_out_srv
                            bus_in_srv = require_dynamic_service(combus_srv.model.dynamic_service_name, :as => dev.name, :direction => 'in')
                            client_out_srv.bind(task).connect_to bus_in_srv
                        end
                    end
                end
            end
        end
end
