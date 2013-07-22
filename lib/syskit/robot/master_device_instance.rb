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
            # The communication busses this device is attached to
            attr_reader :com_busses
            # Additional specifications for deployment of the driver
            # @return [Syskit::InstanceRequirements]
            attr_reader :requirements

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
                @com_busses = Array.new
                @requirements = Syskit::InstanceRequirements.new

                task_arguments["#{driver_model.name}_dev"] = self
                sample_size 1
                burst   0
            end

            def to_s
                "device(#{device_model.short_name}, :as => #{full_name})"
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

            # True if this device is attached to the given combus
            def attached_to?(com_bus)
                com_busses.include?(com_bus)
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
                if com_bus.respond_to?(:to_str)
                    com_bus, com_bus_name = robot.find_device(com_bus), com_bus
                    if !com_bus
                        raise ArgumentError, "no device declared with the name '#{com_bus_name}'"
                    end
                end

                client_in_srv = com_bus.model.client_in_srv
                client_out_srv = com_bus.model.client_out_srv

		options = Kernel.validate_options options,
		    :in => nil, :out => nil

                @combus_in_srv  = find_combus_client_srv(com_bus.model.client_in_srv, options[:in])
                @combus_out_srv = find_combus_client_srv(com_bus.model.client_out_srv, options[:out])
		if !combus_out_srv && !combus_in_srv
		    raise ArgumentError, "#{driver_model.component_model.short_name} provides neither an input nor an output service for combus #{com_bus.name}. It should provide #{com_bus.model.client_in_srv.short_name} for input-only, #{com_bus.model.client_out_srv.short_name} for output-only or #{com_bus.model.client_srv.short_name} for bidirectional connections"
		end
                com_busses << com_bus
                com_bus.attached_devices << self
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
                slaves.each_value(&block)
            end

            # Gets the required slave device, or creates a dynamic one
            #
            # @overload slave(slave_name)
            #   @arg [String] slave_name the name of a slave service on the
            #     device's driver 
            #   @return [Syskit::Robot::SlaveDeviceInstance]
            #
            # @overload slave(dynamic_service_name, :as => slave_name)
            #   @arg [String] dynamic_service_name the name of a dynamic service
            #     declared on the device's driver with #dynamic_service
            #   @arg [String] slave_name the name of the slave as it should be
            #     created
            #   @return [Syskit::Robot::SlaveDeviceInstance]
            #   
            def slave(slave_service, options = Hash.new)
                options = Kernel.validate_options options, :as => nil
                if existing_slave = slaves[slave_service]
                    return existing_slave
                end

                # If slave_service is a string, it should refer to an actual
                # service on +task_model+
                task_model = driver_model.component_model

                slave_name = "#{driver_model.full_name}.#{slave_service}"
                srv = task_model.find_data_service(slave_name)
                if !srv
                    if options[:as]
                        new_task_model = task_model.ensure_model_is_specialized
                        srv = new_task_model.require_dynamic_service(slave_service, :as => options[:as])
                    end
                    if !srv
                        raise ArgumentError, "there is no service #{slave_name} and no dynamic service in #{task_model.short_name}"
                    end
                    @driver_model = driver_model.attach(new_task_model)
                end

                device_instance = SlaveDeviceInstance.new(self, srv)
                slaves[srv.name] = device_instance
                if srv.model.respond_to?(:apply_device_configuration_extensions)
                    srv.model.apply_device_configuration_extensions(device_instance)
                end
                robot.devices["#{name}.#{srv.name}"] = device_instance
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /(.*)_dev$/
                    if !args.empty?
                        raise ArgumentError, "expected no arguments, got #{args.size}"
                    end
                    return slave($1)
                end
                super
            end

            def use_frames(frame_mappings)
                requirements.use_frames(frame_mappings)
            end

            def use_deployments(hints)
                requirements.use_deployments(hints)
                self
            end

            # Returns the InstanceRequirements object that can be used to
            # represent this device
            def to_instance_requirements
                driver_model.to_instance_requirements.
                    with_arguments(task_arguments).
                    merge(requirements)
            end

            def as_plan; to_instance_requirements.as_plan end

            def each_fullfilled_model(&block)
                device_model.each_fullfilled_model(&block)
            end

            DRoby = Struct.new :name, :device_model, :driver_model do
                def proxy(peer)
                    MasterDeviceInstance.new(nil, name, peer.local_object(device_model), Hash.new, peer.local_object(driver_model), Hash.new)
                end
            end
            def droby_dump(peer)
                DRoby.new(name, device_model.droby_dump(peer), driver_model.droby_dump(peer))
            end
        end
    end
end

