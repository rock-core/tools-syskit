# frozen_string_literal: true

module Syskit
    module Robot
        # RobotDefinition objects describe a robot through the devices that are
        # available on it.
        class RobotDefinition
            def initialize
                @devices = {}
            end

            # The devices that are available on this robot
            attr_reader :devices

            # Modify the raw requirements to add context information
            def inject_di_context(requirements); end

            def empty?
                devices.empty?
            end

            def clear
                invalidate_dependency_injection
                devices.clear
            end

            # Add the devices defined in the given robot to the ones defined in
            # self.
            #
            # If robot and self have devices with the same names, the ones in
            # self take precedence
            def use_robot(robot)
                return [] if robot.empty?

                if devices.empty?
                    # Optimize the 'self is empty' codepath because it's
                    # actually very common ... and it allows us to reuse the
                    # caller's DI object
                    @di = robot.to_dependency_injection
                    @devices = robot.devices.dup
                    return devices.values
                end

                new_devices = []
                robot.devices.each do |device_name, device|
                    unless devices.key?(device_name)
                        devices[device_name] = device
                        new_devices << device
                    end
                end
                invalidate_dependency_injection unless new_devices.empty?
                new_devices
            rescue StandardError
                invalidate_dependency_injection
                raise
            end

            # Declares a new communication bus
            def com_bus(type, **options)
                device(type, expected_model: Syskit::ComBus, class: ComBus, **options)
            end

            # Returns true if +name+ is the name of a device registered on this
            # robot model
            def has_device?(name)
                devices.key?(name.to_str)
            end

            # Returns a device by its name
            #
            # @return [DeviceInstance,nil]
            def find_device(name)
                devices[name]
            end

            # Makes all devices declared in the provided block are using
            # the given bus
            #
            # For instance:
            #
            #   through 'can0' do
            #       device 'motors'
            #   end
            #
            # is equivalent to
            #
            #   device('motors').
            #       attach_to('can0')
            #
            def through(com_bus, &block)
                if com_bus.respond_to?(:to_str)
                    unless (bus = find_device(com_bus.to_str))
                        raise ArgumentError, "communication bus #{com_bus} does not exist"
                    end

                    com_bus = bus
                end

                unless com_bus.respond_to?(:through)
                    raise ArgumentError, "#{com_bus} is not a communication bus"
                end

                com_bus.through(&block)
                com_bus
            end

            # Adds a new device to this robot definition.
            #
            # +device_model+ is either the device type or its name. It is
            # implicitely declared by the use of driver_for in component
            # classes, or by using SystemModel#device_type.
            #
            # For instance, if a Hokuyo orogen component is available that can
            # drive Hokuyo laser scanners, then one would declare the driver
            # with:
            #
            #   class Hokuyo
            #       driver_for 'Devices::Hokuyo'
            #   end
            #
            # the newly declared device type can then be accessed as a
            # constant with Devices::Hokuyo. I.e.
            #
            #   Devices::Hokuyo
            #
            # is the subclass of DeviceModel that describes this device type.
            # It can then be used to declare devices on a robot with
            #
            #   Robot.devices do
            #     device Devices::Hokuyo
            #   end
            #
            # This method returns the MasterDeviceInstance instance that
            # describes the actual device
            def device(device_model, doc: nil, **options)
                options, device_options = Kernel.filter_options(
                    options,
                    as: nil,
                    using: nil,
                    expected_model: Syskit::Device,
                    class: MasterDeviceInstance
                )
                device_options, root_task_arguments = Kernel.filter_options(
                    device_options,
                    MasterDeviceInstance::KNOWN_PARAMETERS
                )

                # Check for duplicates
                unless options[:as]
                    raise ArgumentError, "no name given, please provide the :as option"
                end

                name = options[:as]
                if (existing = devices[name])
                    raise ArgumentError, "device '#{name}' is already defined: #{existing}"
                end

                # Verify that the provided device model matches what we expect
                unless device_model < options[:expected_model]
                    raise ArgumentError, "#{device_model} is not a "\
                                         "#{options[:expected_model].short_name}"
                end

                # If the user gave us an explicit selection, honor it
                driver_model =
                    begin options[:using] || device_model.default_driver
                    rescue Ambiguous => e
                        raise e, "#{e.message}, select one explicitely with the "\
                                 "using: option of the 'device' statement", e.backtrace
                    end

                if driver_model.respond_to?(:find_data_service_from_type)
                    driver_model =
                        begin driver_model.find_data_service_from_type(device_model)
                        rescue Syskit::AmbiguousServiceSelection => e
                            raise e, "#{e.message}, select one explicitly with the "\
                                     "using: option of the 'device' statement",
                                  e.backtrace
                        end
                    unless driver_model
                        raise ArgumentError, "#{options[:using]}, given as the using: "\
                                             "option to create #{self}, is not a driver "\
                                             "for #{device_model}"
                    end
                end

                driver_model = driver_model.to_instance_requirements
                device_instance = options[:class].new(
                    self, name, device_model, device_options,
                    driver_model, root_task_arguments
                )
                invalidate_dependency_injection
                device_model.apply_device_configuration_extensions(device_instance)

                doc ||= MetaRuby::DSLs.parse_documentation_block(
                    ->(file) { Roby.app.app_file?(file) },
                    /^device$/
                )
                device_instance.doc(doc)
                register_device(name, device_instance)

                # And register all the slave services there is on the driver
                driver_model.service.each_slave_data_service do |slave_service|
                    slave_device = SlaveDeviceInstance.new(device_instance, slave_service)
                    device_instance.slaves[slave_service.name] = slave_device
                    register_device("#{name}.#{slave_service.name}", slave_device)
                end

                device_instance
            end

            def register_device(name, device_instance)
                devices[name] = device_instance
            end

            def each_device(&block)
                devices.each_value(&block)
            end

            # Enumerates all master devices that are available on this robot
            def each_master_device
                return enum_for(__method__) unless block_given?

                devices.find_all { |_, instance| instance.kind_of?(MasterDeviceInstance) }
                       .each { |_, instance| yield(instance) }
            end

            # Enumerates all slave devices that are available on this robot
            def each_slave_device
                return enum_for(__method__) unless block_given?

                devices.find_all { |_, instance| instance.kind_of?(SlaveDeviceInstance) }
                       .each { |_, instance| yield(instance) }
            end

            def invalidate_dependency_injection
                @di = nil
            end

            # Returns a dependency injection object that maps names to devices
            def to_dependency_injection
                return @di.dup if @di

                result = DependencyInjection.new
                device_model_to_instance = {}
                devices.each_value do |instance|
                    unless device_model_to_instance.delete(instance.device_model)
                        device_model_to_instance[instance.device_model] = instance
                    end
                end
                # Register name-to-device mappings
                result.add(device_model_to_instance)
                result.resolve
                @di = result
                @di.dup
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m, "_dev" => :has_device?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args, "_dev" => :find_device
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing
        end
    end
end
