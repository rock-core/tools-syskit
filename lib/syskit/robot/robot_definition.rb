module Syskit
    module Robot
        # RobotDefinition objects describe a robot through the devices that are
        # available on it.
        class RobotDefinition
            def initialize
                @com_busses = Hash.new
                @devices    = Hash.new
            end

            # The available communication busses
            attr_reader :com_busses
            # The devices that are available on this robot
            attr_reader :devices

            def clear
                com_busses.clear
                devices.clear
            end

            # Declares a new communication bus
            def com_bus(type, options = Hash.new)
                bus_options, _ = Kernel.filter_options options, :as => type.snakename
                name = options[:as].to_str
                if com_busses[name]
                    raise ArgumentError, "there is already a communication bus called #{name}"
                end

                device = device(type, options)
                com_busses[name] = CommunicationBus.new(self, bus_options[:as].to_str, device, options)
                device
            end

            # Returns true if +name+ is the name of a device registered on this
            # robot model
            def has_device?(name)
                devices.has_key?(name.to_str)
            end

            # Declares that all devices declared in the provided block are using
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
                bus = com_busses[com_bus.to_str]
                if !bus
                    raise SpecError, "communication bus #{com_bus} does not exist"
                end
                bus.through(&block)
                bus
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
            def device(device_model, options = Hash.new)
                if !(device_model < Device)
                    raise ArgumentError, "expected a device model, got #{device_model} of class #{device_model.class.name}"
                end

                options, device_options = Kernel.filter_options options,
                    :as => device_model.snakename,
                    :using => nil,
                    :expected_model => Device
                device_options, task_arguments = Kernel.filter_options device_options,
                    MasterDeviceInstance::KNOWN_PARAMETERS

                # Check for duplicates
                name = options[:as].to_str
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                # Verify that the provided device model matches what we expect
                if !(device_model < options[:expected_model])
                    raise SpecError, "#{device_model} is not a #{options[:expected_model].name}"
                end

                # If the user gave us an explicit selection, honor it
                explicit_selection = options[:using]
                if explicit_selection.kind_of?(Models::BoundDataService)
                    task_model = explicit_selection.task_model
                    service = explicit_selection
                else
                    task_model = explicit_selection
                end

                if !task_model
                    # Since we want to drive a particular device, we actually need a
                    # concrete task model. So, search for one.
                    #
                    # Get all task models that implement this device
                    tasks = TaskContext.submodels.
                        find_all { |t| t.fullfills?(device_model) }

                    # Now, get the most abstract ones
                    tasks.delete_if do |model|
                        tasks.any? { |t| model < t }
                    end

                    if tasks.size > 1
                        raise Ambiguous, "#{tasks.map(&:short_name).join(", ")} can all handle '#{device_model.short_name}', please select one explicitely with the 'using' statement"
                    elsif tasks.empty?
                        raise SpecError, "no task can handle devices of type '#{device_model.short_name}'"
                    end
                    task_model = tasks.first
                end

                if service
                    if !service.fullfills?(device_model)
                        raise ArgumentError, "selected service #{service.name} from #{task_model.short_name} cannot handle devices of type #{device_model.short_name}"
                    end
                else
                    service_candidates = task_model.find_all_services_from_type(device_model)
                    if service_candidates.empty?
                        raise ArgumentError, "#{task_model.short_name} has no service of type #{device_model.short_name}"
                    elsif service_candidates.size > 1
                        raise ArgumentError, "more than one service in #{task_model.short_name} provide #{device_model.short_name}, you need to select one with the 'using_service' statement"
                    end
                    service = service_candidates.first
                end

                root_task_arguments = { "#{service.name}_name" => name }.
                    merge(task_arguments)

                device_instance = MasterDeviceInstance.new(
                    self, name, device_model, device_options,
                    task_model, service, root_task_arguments)
                devices[name] = device_instance
                device_model.apply_device_configuration_extensions(devices[name])

                # And register all the slave services there is on the driver
                task_model.each_slave_data_service(service) do |slave_service|
                    slave_device = SlaveDeviceInstance.new(devices[name], slave_service)
                    device_instance.slaves[slave_service.name] = slave_device
                    devices["#{name}.#{slave_service.name}"] = slave_device
                end

                device_instance
            end

            def each_device(&block)
                devices.each(&block)
            end

            # Enumerates all master devices that are available on this robot
            def each_master_device(&block)
                devices.find_all { |name, instance| instance.kind_of?(MasterDeviceInstance) }.
                    each(&block)
            end

            # Enumerates all slave devices that are available on this robot
            def each_slave_device(&block)
                devices.find_all { |name, instance| instance.kind_of?(SlaveDeviceInstance) }.
                    each(&block)
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block_given?
                    if dev = devices[m.to_s]
                        return dev
                    end
                end

                super
            end
        end
    end
end

