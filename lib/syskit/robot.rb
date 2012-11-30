module Syskit
        # A DeviceInstance object is used to represent an actual device on the
        # system
        #
        # It is returned by Robot.device
        class DeviceInstance
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

            # Declares that this particular device might "every once in a while"
            # sent bursts of data. This is used by the automatic connection code
            # to compute buffer sizes
            dsl_attribute(:burst)   { |v| Integer(v) }
        end

        # Subclass of DeviceInstance used to represent root devices
        class MasterDeviceInstance < DeviceInstance
            # The RobotDefinition instance we are built upon
            attr_reader :robot
            # The device name
            attr_reader :name
            # The device model, as a subclass of Device
            attr_reader :device_model
            # The device slaves, as a mapping from the slave's name to the
            # SlaveDeviceInstance object
            attr_reader :slaves

            def model; device_model end

            # Defined to be consistent with task and data service models
            def short_name
                "#{name}[#{model.short_name}]"
            end

            # [Models::TaskContext] The selected task model that allows to drive this device
            attr_reader :task_model
            # [Models::BoundDataService] The data service that will drive this device
            attr_reader :service
            # The task arguments
            attr_reader :task_arguments
            # The actual task
            attr_accessor :task
            # Configuration data structure
            attr_reader :configuration
            # Block given to #configure to configure the device. It will be
            # yield a data structure that represents the set of properties of
            # the underlying task
            #
            # Note that it is executed twice. Once at loading time to verify
            # that the block is compatible with the data structure, and once at
            # runtime to actually configure the task
            attr_reader :configuration_block

            def initialize(robot, name, device_model, options,
                           task_model, service, task_arguments)
                @robot, @name, @device_model, @task_model, @service, @task_arguments =
                    robot, name, device_model, task_model, service, task_arguments
                @slaves      = Hash.new
                @conf = Array.new

                sample_size 1
                burst   0
            end

            def full_name
                name
            end

            # @deprecated
            def use_conf(*conf)
                Roby.warn_deprecated "MasterDeviceInstance#use_conf is deprecated. Use #with_conf instead"
                with_conf(*conf)
            end

            # Declares that the following configuration chain should be used for
            # this device
            def with_conf(*conf)
                task_arguments[:conf] = conf
                self
            end

            # Returns the names of the com busses this device instance is
            # connected to
            def com_bus_names
                result = []
                @task_arguments.each do |arg_name, bus_name|
                    if arg_name.to_s =~ /_com_bus$/ && bus_name
                        result << bus_name
                    end
                end
                result
            end

            # True if this device is attached to the given combus
            def attached_to?(com_bus)
                com_bus = com_bus.name if com_bus.respond_to?(:name)
                task_arguments["#{service.name}_com_bus"] == com_bus
            end

            # Attaches this device on the given communication bus
            def attach_to(com_bus)
                if !com_bus.kind_of?(CommunicationBus)
                    com_bus = robot.com_busses[com_bus.to_str]
                end
                task_arguments["#{service.name}_com_bus"] = com_bus.name
                com_bus.model.apply_attached_device_configuration_extensions(self)
                self
            end

            # call-seq:
            #   device.configure { |p| }
            #
            # Yields a data structure that can be used to configure the given
            # device. The type of the data structure is declared in the
            # driver_for and data_service statement using the :config_type
            # option.
            #
            # It will raise ArgumentError if the driver model did *not* declare
            # a configuration type.
            #
            # See the documentation of each task context for details on the
            # specific configuration parameters.
            def configure(base_config = nil, &config_block)
		if base_config
		    @configuration = base_config.dup
		end
                if block_given?
                    if @configuration
                        yield(@configuration)
                    else
                        if !service.config_type
                            raise ArgumentError, "#configure called on #{self.name}, but there is no configuration type for this device"
                        end

                        # Just verify that there is no error in
                        # configuration_block
                        yield(service.config_type.new)
                    end
                end
                @configuration_block = config_block
                self
            end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil, :device_id => nil }

            def instanciate(engine, context, options = Hash.new)
                options[:task_arguments] = task_arguments.merge(options[:task_arguments] || Hash.new)
                task_model.instanciate(engine, context, options)
            end

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

            # Enumerates the slaves that are known for this device, as
            # [slave_name, SlaveDeviceInstance object] pairs
            def each_slave(&block)
                slaves.each(&block)
            end

            def slave(slave_service, options = Hash.new)
                options = Kernel.validate_options options, :as => nil

                # If slave_service is a string, it should refer to an actual
                # service on +task_model+
                if slave_service.respond_to?(:to_str)
                    srv = task_model.find_service(slave_service)
                    if !srv
                        raise ArgumentError, "there is no service in #{task_model.short_name} named #{slave_service}"
                    end
                elsif slave_service.kind_of?(DataServiceModel)
                    srv = task_model.find_matching_service(slave_service, options[:as])
                    if !srv
                        options[:as] ||= slave_service.snakename
                        new_task_model, srv = self.service.
                            require_dynamic_slave(slave_service, options[:as], name, task_model)

                        if !srv
                            raise ArgumentError, "there is no service in #{task_model.short_name} of type #{slave_service.short_name}"
                        end

                        @task_model = new_task_model

                        SystemModel.debug do
                            SystemModel.debug "dynamically created slave service #{name}.#{srv.name} of type #{srv.model.short_name} from #{slave_service.short_name}"
                            break
                        end
                        device_instance = SlaveDeviceInstance.new(self, srv)
                        slaves[srv.name] = device_instance
                        srv.model.apply_device_configuration_extensions(device_instance)
                        robot.devices["#{name}.#{srv.name}"] = device_instance
                    end
                else
                    raise ArgumentError, "expected #{slave_service} to be either a string or a data service model"
                end
            end

            # Allows calling
            #
            #   device.blabla_slave
            #
            # to access a device slave
            def method_missing(m, *args, &block)
                if m.to_s =~ /(.*)_slave$/ && (!block && args.empty?)
                    if s = slaves[$1]
                        return s
                    end
                end
                return super
            end
        end

        # A SlaveDeviceInstance represents slave devices, i.e. data services
        # that are provided by other devices. For instance, a camera image from
        # a stereocamera device.
        class SlaveDeviceInstance < DeviceInstance
            # The MasterDeviceInstance that we depend on
            attr_reader :master_device
            # The actual service on master_device's task model
            attr_reader :service

            def robot
                master_device.robot
            end

            def task_model
                master_device.task_model
            end

            def device_model
                service.model
            end

            # The slave name. It is the same name than the corresponding service
            # on the task model
            def name
                service.name
            end

            def full_name
                "#{master_device.name}.#{name}"
            end

            # Defined to be consistent with task and data service models
            def short_name
                "#{name}[#{service.model.short_name}]"
            end

            def initialize(master_device, service)
                @master_device = master_device
                @service = service
            end

            def task; master_device.task end

            def period(*args)
                if args.empty?
                    super || master_device.period
                else
                    super
                end
            end
            def sample_size(*args)
                if args.empty?
                    super || master_device.sample_size
                else
                    super
                end
            end
            def burst(*args)
                if args.empty?
                    super || master_device.burst
                else
                    super
                end
            end
        end

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

