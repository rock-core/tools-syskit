# frozen_string_literal: true

module Syskit
    module Robot
        # A DeviceInstance object is used to represent an actual device on the
        # system
        #
        # It is returned by Robot.device
        class DeviceInstance
            # Gets or sets the device period
            #
            # The device period is the amount of time there is between two
            # samples coming from the device. The value is a floating-point
            # value in seconds.
            #
            # @return [Float]
            dsl_attribute(:period) { |v| Float(v) }

            # Gets or sets a documentation string for this device
            #
            # @return [String]
            dsl_attribute(:doc) { |s| s&.to_str }

            # If this device is on a communication bus, the sample_size
            # statement specifies how many messages on the bus are required to
            # form one of the device sample.
            #
            # For instance, if four motor controllers are modelled as one device
            # on a CAN bus, and if each of them require one message, then the
            # following would be used to declare the device:
            #
            #   device(Motors).
            #       device_id(0x0, 0x700).
            #       period(0.001).sample_size(4)
            #
            # It is unused for devices that don't communicate through a bus.
            #
            dsl_attribute(:sample_size) { |v| Integer(v) }

            # Declares that this particular device might "every once in a while"
            # sent bursts of data. This is used by the automatic connection code
            # to compute buffer sizes
            dsl_attribute(:burst) { |v| Integer(v) }

            def to_action
                to_instance_requirements.to_action
            end

            def instanciate(plan, context = DependencyInjectionContext.new, **options)
                to_instance_requirements.instanciate(plan, context, **options)
            end
        end
    end
end
