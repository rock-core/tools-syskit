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

            # The driver for this device
            # @return [BoundDataService]
            attr_reader :driver_model
            # The task arguments
            attr_reader :task_arguments
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
                           driver_model, task_arguments)
                @robot, @name, @device_model, @driver_model, @task_arguments =
                    robot, name, device_model, driver_model, task_arguments
                @slaves      = Hash.new
                @conf = Array.new

                task_arguments["#{driver_model.name}_dev"] = self
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
                task_arguments["#{driver_model.name}_com_bus"] == com_bus
            end

            # The data service of {#task_model} that is used to receive data from
            # the attached com bus for this device. If nil, the task is not
            # expecting to receive any data from the communication bus (only
            # send)
            #
            # @return [BoundDataService,nil]
            attr_reader :combus_in_srv

            # The data service of {#task_model} that is used to send data to
            # the attached com bus for this device. If nil, the task is not
            # expecting to send any data from the communication bus (only
            # receives)
            #
            # @return [BoundDataService,nil]
            attr_reader :combus_out_srv

            # Attaches this device on the given communication bus
	    #
	    # @option options [String] :in the name of the service on the device
	    #   driver task context that should be used to get data from the
	    #   communication bus. It is needed only if there is an ambiguity
	    # @option options [String] :out the name of the service on the device
	    #   driver task context that should be used to send data to the
	    #   communication bus. It is needed only if there is an ambiguity
            def attach_to(com_bus, options = Hash.new)
                if !com_bus.respond_to?(:name)
                    com_bus_name = com_bus.to_str
                    com_bus = robot.devices[com_bus_name]
                    if !com_bus
                        raise ArgumentError, "#{com_bus_name} is not a known communication bus"
                    end
                end

                client_in_srv = com_bus.model.client_in_srv
                client_out_srv = com_bus.model.client_out_srv

		options = Kernel.validate_options options,
		    :in => nil, :out => nil
                task_arguments["#{driver_model.name}_com_bus"] = com_bus.name

                @combus_in_srv  = find_combus_client_srv(com_bus.model.client_in_srv, options[:in])
                @combus_out_srv = find_combus_client_srv(com_bus.model.client_out_srv, options[:out])
		if !combus_out_srv && !combus_in_srv
		    raise ArgumentError, "#{driver_model.component_model.short_name} provides neither an input nor an output service for combus #{com_bus.name}"
		end
                com_bus.model.apply_attached_device_configuration_extensions(self)
                self
            end
            
            # Finds in {#driver_model}.component_model the data service that should be used to
            # interface with a combus
            #
            # @param [Model<DataService>] the data service model for the client
            #   interface to the combus
            # @param [String,nil] the expected data service name, or nil if none
            #   is given. In this case, one is searched by type
            def find_combus_client_srv(srv_m, srv_name)
		if srv_name
		    result = driver_model.component_model.find_data_service(srv_name)
		    if !result
			raise ArgumentError, "#{srv_name} is specified as a client service on device #{name} for combus #{com_bus.name}, but it is not a data service on #{driver_model.component_model.short_name}"
                    elsif !result.fullfills?(srv_m)
                        raise ArgumentError, "#{srv_name} is specified as a client service on device #{name} for combus #{com_bus.name}, but it does not provide the required service from #{com_bus.model.short_name}"
		    end
                    result
		else
		    driver_model.component_model.find_data_service_from_type(srv_m)
		end
            end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil, :device_id => nil }

            def instanciate(plan, context, options = Hash.new)
                options[:task_arguments] = task_arguments.merge(options[:task_arguments] || Hash.new)
                driver_model.instanciate(plan, context, options)
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

            # Gets the required slave device
            def slave(slave_service, options = Hash.new)
                options = Kernel.validate_options options, :as => nil

                # If slave_service is a string, it should refer to an actual
                # service on +task_model+
                srv = task_model.find_data_service(slave_service)
                if !srv
                    new_task_model = task_model.ensure_model_is_specialized
                    srv = new_task_model.require_dynamic_service(slave_service, :as => options[:as])
                    if !srv
                        raise ArgumentError, "there is no service and no dynamic service in #{task_model.short_name} named #{slave_service}"
                    end
                    @task_model = new_task_model
                end

                device_instance = SlaveDeviceInstance.new(self, srv)
                slaves[srv.name] = device_instance
                srv.model.apply_device_configuration_extensions(device_instance)
                robot.devices["#{name}.#{srv.name}"] = device_instance
            end

            # Returns the InstanceRequirements object that can be used to
            # represent this device
            def to_instance_requirements
                driver_model.to_instance_requirements.
                    with_arguments(task_arguments)
            end
        end
    end
end

