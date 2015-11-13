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
                if !device_model.lazy_dispatch?
                    messages_direction = device_model.messages_direction
                    each_attached_device do |dev|
                        task.require_dynamic_service(
                            device_model.dynamic_service_name,
                            as: dev.name, direction: messages_direction)
                    end
                end
                service
            end

            def through(&block)
                instance_eval(&block)
            end

            def each_attached_device
                attached_devices.each { |dev| yield(dev) }
            end

            # Used by the #through call to override com_bus specification.
            def device(type_name, options = Hash.new)
                device = robot.device(type_name, options)
                device.attach_to(self)
                device
            end
        end
    end
end

