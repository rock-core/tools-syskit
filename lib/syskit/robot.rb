module Orocos
    module RobyPlugin
        # A DeviceInstance object is used to represent an actual device on the
        # system
        #
        # It is returned by Robot.device
        class DeviceInstance; end

        # Specialization of MasterDeviceInstance used to represent root devices
        class MasterDeviceInstance
            # The device name
            attr_reader :name
            # The device model, as a subclass of DataSource
            attr_reader :device_model

            # The selected task model that allows to drive this device
            attr_reader :task_model
            # The source in +task_model+ for this device
            attr_reader :task_source_name
            # The task arguments
            attr_reader :task_arguments
            # The actual task
            attr_accessor :task

            # Generic property map. The values are set with #set and can be
            # retrieved by calling "self.property_name". The possible values are
            # specific to the type of device
            attr_reader :properties

            def com_bus; @task_arguments[:com_bus] end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil, :device_id => nil }
            def initialize(name, device_model, options,
                           task_model, task_source_name, task_arguments)
                @name, @device_model, @task_model, @task_source_name, @task_arguments =
                    name, device_model, task_model, task_source_name, task_arguments

                @period      = options[:period]
                @sample_size = options[:sample_size]
                @device_id   = options[:device_id]
                @properties  = Hash.new
            end

            def instanciate(engine)
                task_model.instanciate(engine, task_arguments)
            end

            def set(name, *values)
                if values.size == 1
                    properties[name.to_str] = values.first
                else
                    properties[name.to_str] = values
                end
                self
            end

            ##
            # :method:period
            #
            # call-seq:
            #   period(new_period) => new_period
            #   period => current_period or nil
            #
            # Gets or sets the device period
            #
            # The device period is the amount of time there is between two
            # samples coming from the device. The value is a floating-point
            # value in seconds.
            dsl_attribute(:period) { |v| Float(v) }

            ## 
            # :method:sample_size
            #
            # call-seq:
            #   sample_size(size)
            #   sample_size => current_size
            #
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

            ## 
            # :method:device_id
            #
            # call-seq:
            #   device_id(device_id, definition)
            #   device_id => current_id or nil
            #
            # The device ID. It is dependent on the method of communication to
            # the device. For a serial line, it would be the device file
            # (/dev/ttyS0):
            #
            #   device(XsensImu).
            #       device_id('/dev/ttyS0')
            #
            # For CAN, it would be the device ID and mask:
            #
            #   device(Motors).
            #       device_id(0x0, 0x700)
            #
            dsl_attribute(:device_id) do |*values|
                if values.size > 1
                    values
                else
                    values.first
                end
            end
        end

        # A SlaveDeviceInstance represents slave devices, i.e. data services
        # that are provided by other devices. For instance, a camera image from
        # a stereocamera device.
        class SlaveDeviceInstance
            # The MasterDeviceInstance that we depend on
            attr_reader :master_device
            # Which slave of master_device this is representing
            attr_reader :slave_name
            # The data service model for this slave
            attr_reader :data_service_model

            def initialize(master_device, slave_name, data_service_model)
                @master_device = master_device
                @slave_name    = slave_name
                @data_service_model = data_service_model
            end

            def task; master_device.task end

            def period;      master_device.period end
            def sample_size; master_device.sample_size end
        end

        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class CommunicationBus
            # The RobotDefinition object we are part of
            attr_reader :robot
            # The bus name
            attr_reader :name

            def initialize(robot, name, options = Hash.new)
                @robot = robot
                @name  = name
                @options = options
            end

            def through(&block)
                with_module(*RobyPlugin.constant_search_path, &block)
            end

            # Used by the #through call to override com_bus specification.
            def device(type_name, options = Hash.new)
                # Check that we do have the configuration data for that device,
                # and declare it as being passing through us.
                if options[:com_bus] || options['com_bus']
                    raise SpecError, "cannot use the 'com_bus' option in a through block"
                end
                options[:com_bus] = self.name
                robot.device(type_name, options)
            end
        end

        # RobotDefinition objects describe a robot through the devices that are
        # available on it.
        class RobotDefinition
            def initialize(engine)
                @engine     = engine
                @com_busses = Hash.new
                @devices    = Hash.new
            end

            # The underlying engine
            attr_reader :engine
            # The available communication busses
            attr_reader :com_busses
            # The devices that are available on this robot
            attr_reader :devices

            # Declares a new communication bus. It is both seen as a device and
            # as a com bus, and as such is registered in both the devices and
            # com_busses hashes
            def com_bus(type_name, options = Hash.new)
                bus_options, _ = Kernel.filter_options options, :as => type_name
                name = bus_options[:as].to_str
                com_busses[name] = CommunicationBus.new(self, name, options)

                device(type_name, options)
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
            #   m = device 'motors'
            #   m.com_bus 'can0'
            #
            def through(com_bus, &block)
                bus = com_busses[com_bus]
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
            #       driver_for 'hokuyo'
            #   end
            #
            # the newly declared device type can then be accessed as a
            # constant with DataSources::Hokuyo or as a name:
            #
            #   robot.device 'hokuyo'
            #   robot.device DataSources::Hokuyo
            #
            # Returns the MasterDeviceInstance object that describes this device
            def device(device_model, options = Hash.new)
                if device_model.respond_to?(:to_str)
                    device_model = Orocos::RobyPlugin::DataSources.const_get(device_model.to_str.camelcase(true))
                elsif device_model < DataService && !(device_model < DataSource)
                    name = device_model.name
                    if engine.model.has_data_source?(name)
                        device_model = Orocos::RobyPlugin::DataSources.const_get(name.camelcase(true))
                    end
                end

                options, device_options = Kernel.filter_options options,
                    :as => device_model.name.gsub(/.*::/, '').snakecase,
                    :expected_model => DataSource
                device_options, task_arguments = Kernel.filter_options device_options,
                    MasterDeviceInstance::KNOWN_PARAMETERS

                name = options[:as].to_str
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                if !(device_model < options[:expected_model])
                    raise SpecError, "#{device_model} is not a #{options[:expected_model].name}"
                end

                # Since we want to drive a particular device, we actually need a
                # concrete task model. So, search for one.
                #
                # Get all task models that implement this device
                tasks = Roby.app.orocos_tasks.
                    find_all { |_, t| t.fullfills?(device_model) }.
                    map { |_, t| t }

                # Now, get the most abstract ones
                tasks.delete_if do |model|
                    tasks.any? { |t| model < t }
                end

                if tasks.size > 1
                    raise Ambiguous, "#{tasks.map(&:name).join(", ")} can all handle '#{name}', please select one explicitely with the 'using' statement"
                elsif tasks.empty?
                    raise SpecError, "no task can handle devices of type '#{device_model}'"
                end

                task_model = tasks.first
                task_source_name = task_model.data_service_name(device_model)
                root_task_arguments = {"#{task_source_name}_name" => name, :com_bus => nil}.
                    merge(task_arguments)

                devices[name] = MasterDeviceInstance.new(
                    name, device_model, device_options,
                    task_model, task_source_name, root_task_arguments)

                task_model.each_child_data_service(task_source_name) do |child_name, child_model|
                    devices["#{name}.#{child_name}"] = SlaveDeviceInstance.new(devices[name], child_name, child_model)
                end

                devices[name]
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
        end
    end
end

