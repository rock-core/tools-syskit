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

