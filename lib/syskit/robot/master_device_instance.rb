module Syskit
    module Robot
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
                    srv = task_model.find_data_service(slave_service)
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
    end
end

