module Syskit
    module Robot
        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class CommunicationBus
            # The RobotDefinition object we are part of
            attr_reader :robot
            # The bus name
            attr_reader :name
            # The device instance object that drivers this communication bus
            attr_reader :device_instance
            # Returns the ComBus submodel that models this
            # communication bus
            def model; device_instance.model end

            def initialize(robot, name, device, options = Hash.new)
                @robot = robot
                @name  = name
                @device_instance = device
                @options = options
            end

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

