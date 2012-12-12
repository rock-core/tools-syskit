module Syskit
    module Robot
        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class ComBus < MasterDeviceInstance
            def through(&block)
                instance_eval(&block)
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

