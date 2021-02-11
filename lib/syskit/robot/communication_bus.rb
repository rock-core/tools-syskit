# frozen_string_literal: true

module Syskit
    module Robot
        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class ComBus < MasterDeviceInstance
            attr_reader :attached_devices

            def initialize(robot, name, device_model, options,
                driver_model, task_arguments)
                super
                @attached_devices = Set.new
            end

            def instanciate(plan, context = DependencyInjectionContext.new, **options)
                service = super
                task = service.to_task
                unless device_model.lazy_dispatch?
                    each_attached_device do |dev|
                        require_dynamic_service_for_device(task, dev)
                    end
                end
                service
            end

            # Create the dynamic service on the combus driver task that is
            # necessary to connect to the given device
            #
            # @param [Component] combus_task the driver task for self
            # @param [Device] device the device that should be interfaced
            #   through the service
            # @return [BoundDataService] the created service
            def require_dynamic_service_for_device(combus_task, device)
                combus_task.require_dynamic_service(
                    device_model.dynamic_service_name,
                    as: device.name,
                    bus_to_client: device.bus_to_client?,
                    client_to_bus: device.client_to_bus?
                )
            end

            def through(&block)
                instance_eval(&block)
            end

            def each_attached_device(&block)
                attached_devices.each(&block)
            end

            # Used by the #through call to override com_bus specification.
            def device(type_name, bus_to_client: true, client_to_bus: true, **options)
                device = robot.device(type_name, **options)
                device.attach_to(self, bus_to_client: bus_to_client,
                                       client_to_bus: client_to_bus)
                device
            end
        end
    end
end
