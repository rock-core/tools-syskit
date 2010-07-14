module Orocos
    module RobyPlugin
        # Namespace in which data services are stored.
        #
        # When a service is declared with
        #
        #   data_service 'a_name_in_snake_case'
        #
        # The plugin creates a
        # Orocos::RobyPlugin::DataServices::ANameInSnakeCase instance of the
        # DataServiceModel class. This instance then gets included in every task
        # context model and device model that provides the service.
        #
        # A Orocos::Generation::TaskContext instance is used to represent the
        # service interface. This instance is available through the 'interface'
        # attribute of the DataServiceModel instance.
        module DataServices
            def self.each
                constants.each do |name|
                    yield(const_get(name))
                end
            end
        end

        # Namespace in which device models are stored.
        #
        # When a device is declared with
        #
        #   device 'a_name_in_snake_case'
        #
        # The plugin creates a
        # Orocos::RobyPlugin::Devices::ANameInSnakeCase instance of the
        # DataServiceModel class. This instance then gets included in every task
        # context model that provides the service.
        #
        # A Orocos::Generation::TaskContext instance is used to represent the
        # service interface. This instance is available through the 'interface'
        # attribute of the DataServiceModel instance.
        module Devices
            def self.each
                constants.each do |name|
                    yield(const_get(name))
                end
            end
        end

        DataSources = Devices
        DServ = DataServices
        DSrc  = DataSources

        # Base type for data service models (DataService, DataSource,
        # DataBus). Methods defined in this class are available on said
        # models (for instance DataSource.new_submodel)
        class DataServiceModel < Roby::TaskModelTag
            # The name of the model
            attr_accessor :name
            # The parent model, if any
            attr_reader :parent_model

            def short_name
                name.gsub('Orocos::RobyPlugin::', '')
            end

            # Creates a new DataServiceModel that is a submodel of +self+
            def new_submodel(name, options = Hash.new)
                options = Kernel.validate_options options,
                    :type => self.class, :interface => nil

                model = options[:type].new
                model.include self
                model.instance_variable_set(:@parent_model, self)
                model.name = name.dup

                if options[:interface] != false
                    if options[:interface]
                        iface_spec = Roby.app.get_orocos_task_model(options[:interface]).orogen_spec

                        # If we also have an interface, verify that the two
                        # interfaces are compatible
                        if interface 
                            if !iface_spec.implements?(interface.name)
                                raise SpecError, "data service #{name}'s interface, #{options[:interface].name} is not a specialization of #{self.name}'s interface #{self.interface.name}"
                            end
                        end
                        model.instance_variable_set(:@orogen_spec, iface_spec)
                    elsif interface
                        child_spec = model.create_orogen_interface
                        child_spec.subclasses interface.name
                        model.instance_variable_set :@orogen_spec, child_spec
                    else
                        model.instance_variable_set :@orogen_spec, model.create_orogen_interface
                    end
                end
                model
            end

            def create_orogen_interface
                RobyPlugin.create_orogen_interface(name)
            end

            attr_reader :orogen_spec

            def interface(&block)
                if block_given?
                    @orogen_spec ||= create_orogen_interface
                    orogen_spec.instance_eval(&block)
                end
                orogen_spec
            end

            def each_port_name_candidate(port_name, main_service = false, source_name = nil)
                if !block_given?
                    return enum_for(:each_port_name_candidate, port_name, main_service, source_name)
                end

                if source_name
                    if main_service
                        yield(port_name)
                    end
                    yield("#{source_name}_#{port_name}".camelcase(false))
                    yield("#{port_name}_#{source_name}".camelcase(false))
                else
                    yield(port_name)
                end
                self
            end

            # Try to guess the name under which a data service whose model is
            # +self+ could be declared on +model+, by following port name rules.
            #
            # Returns nil if no match has been found
            def guess_source_name(model)
                port_list = lambda do |m|
                    result = Hash.new { |h, k| h[k] = Array.new }
                    m.each_output do |source_port|
                        result[ [true, source_port.type_name] ] << source_port.name
                    end
                    m.each_input do |source_port|
                        result[ [false, source_port.type_name] ] << source_port.name
                    end
                    result
                end

                required_ports  = port_list[self]
                available_ports = port_list[model]

                candidates = nil
                required_ports.each do |spec, names|
                    return if !available_ports.has_key?(spec)

                    available_names = available_ports[spec]
                    names.each do |required_name|
                        matches = available_names.map do |n|
                            if n == required_name then ''
                            elsif n =~ /^(.+)#{Regexp.quote(required_name).capitalize}$/
                                $1
                            elsif n =~ /^#{Regexp.quote(required_name)}(.+)$/
                                name = $1
                                name[0, 1] = name[0, 1].downcase
                                name
                            end
                        end.compact

                        if !candidates
                            candidates = matches
                        else
                            candidates.delete_if { |candidate_name| !matches.include?(candidate_name) }
                        end
                        return if candidates.empty?
                    end
                end

                candidates
            end

            # Returns true if a port mapping is needed between the two given
            # data services. Note that this relation is symmetric.
            #
            # It is assumed that the name0 service in model0 and the name1
            # service
            # in model1 are of compatible types (same types or derived types)
            def self.needs_port_mapping?(from, to)
                from.port_mappings != to.port_mappings
            end

            # Returns the most generic task model that implements +self+. If
            # more than one task model is found, raises Ambiguous
            def task_model
                if @task_model
                    return @task_model
                end

                @task_model = Class.new(DataServiceProxy)
                @task_model.abstract
                @task_model.instance_variable_set(:@orogen_spec, orogen_spec)
                @task_model.name = name
                @task_model.data_service self
                @task_model
            end

            include ComponentModel

            def instanciate(*args, &block)
                task_model.instanciate(*args, &block)
            end

            def to_s # :nodoc:
                "#<DataService: #{name}>"
            end
        end

        DataService  = DataServiceModel.new
        DataSource   = DataServiceModel.new
        ComBusDriver = DataServiceModel.new

        module DataService
            @name = "Orocos::RobyPlugin::DataService"

            def to_short_s
                to_s.gsub /Orocos::RobyPlugin::/, ''
            end

            module ClassExtension
                def find_data_services(&block)
                    each_data_service.find_all(&block)
                end

                def each_data_source(&block)
                    each_data_service.find_all { |_, srv| srv.model < DataSource }.
                        each(&block)
                end

                # Generic data service selection method, based on a service type
                # and an optional service name. It implements the following
                # algorithm:
                #  
                #  * only services that match +target_model+ are considered
                #  * if there is only one service of that type and no pattern is
                #    given, that service is returned
                #  * if there is a pattern given, it must be either the service
                #    full name or its subname (for slaves)
                #  * if an ambiguity is found between root and slave data
                #    services, and there is only one root data service matching,
                #    that data service is returned.
                def find_matching_service(target_model, pattern = nil)
                    # Find services in +child_model+ that match the type
                    # specification
                    matching_services = self.
                        find_data_services { |name, dserv| dserv.model <= target_model }.
                        map(&:last)

                    if pattern # explicit selection
                        # Find the selected service. There can be shortcuts, so
                        # for instance bla.left would be able to select both the
                        # 'left' main service or the 'bla.blo.left' slave
                        # service.
                        rx = /(^|\.)#{pattern}$/
                        matching_services.delete_if { |service| service.full_name !~ rx }
                        if matching_services.empty?
                            raise SpecError, "no service of type #{target_model.name} with the name #{pattern} exists in #{name}"
                        end
                    else
                        if matching_services.empty?
                            raise SpecError, "no data service of type #{target_model} found in #{self}"
                        end
                    end

                    if matching_services.size > 1
                        main_matching_services = matching_services.
                            find_all { |service| service.master? }

                        if main_matching_services.size != 1
                            raise Ambiguous, "there is more than one service of type #{target_model.name} in #{self.name}: #{matching_services.map(&:name).join(", ")}); you must select one explicitely with a 'use' statement"
                        end
                        selected = main_matching_services.first
                    else
                        selected = matching_services.first
                    end

                    selected
                end

                # Returns all data services that offer the given service type
                #
                # Raises ArgumentError if there is not exactly one of such
                # service. Use #all_services_from_type to get all the service
                # names.
                def all_services_from_type(matching_type)
                    each_data_service.find_all do |name, ds|
                        ds.model <= matching_type
                    end
                end

                # Returns a single data service definition that matches the
                # given service type
                #
                # Raises ArgumentError if there is not exactly one of such
                # service. Use #all_services_from_type to get all the service
                # names.
                def service_from_type(matching_type)
                    candidates = all_services_from_type(matching_type)
                    if candidates.empty?
                        raise ArgumentError, "no service of type '#{matching_type.name}' declared on #{self}"
                    elsif candidates.size > 1
                        raise ArgumentError, "multiple services of type #{matching_type.name} are declared on #{self}"
                    end
                    candidates.first
                end

                # Returns the type of the given data service, or raises
                # ArgumentError if no such service is declared on this model
                def data_service_type(name)
                    service = find_data_service(name)
                    if service
                        return service.model
                    end
                    raise ArgumentError, "no service #{name} is declared on #{self}"
                end


                # call-seq:
                #   TaskModel.each_slave_data_service do |name, service|
                #   end
                #
                # Enumerates all services that are slave (i.e. not slave of other
                # services)
                def each_slave_data_service(master_service, &block)
                    each_data_service(nil).
                        find_all { |name, service| service.master == master_service }.
                        map { |name, service| [service.name, service] }.
                        each(&block)
                end


                # call-seq:
                #   TaskModel.each_root_data_service do |name, source_model|
                #   end
                #
                # Enumerates all services that are root (i.e. not slave of other
                # services)
                def each_root_data_service(&block)
                    each_data_service(nil).
                        find_all { |name, srv| srv.master? }.
                        each(&block)
                end
            end

            # Returns true if +self+ can replace +target_task+ in the plan. The
            # super() call checks graph-declared dependencies (i.e. that all
            # dependencies that +target_task+ meets are also met by +self+.
            #
            # This method checks that +target_task+ and +self+ do not represent
            # two different data services
            def can_merge?(target_task)
                return false if !super
                return if !target_task.kind_of?(DataService)

                # Check that for each data service in +target_task+, we can
                # allocate a corresponding service in +self+
                each_source_merge_candidate(target_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        return false
                    end

                    # Note: implementing port mapping will require to apply the
                    # port mappings to the test below as well (i.e. which tests
                    # that inputs are free/compatible)
                    if DataServiceModel.needs_port_mapping?(other_service, self_services.first)
                        raise NotImplementedError, "mapping data flow ports is not implemented yet"
                    end
                end

                true
            end

            # Replace +merged_task+ by +self+, possibly modifying +self+ so that
            # it is possible.
            def merge(merged_task)
                # First thing to do is reassign data services from the merged
                # task into ourselves. Note that we do that only for services
                # that are actually in use.
                each_source_merge_candidate(merged_task) do |selected_source_name, other_service, self_services|
                    if self_services.empty?
                        raise SpecError, "trying to merge #{merged_task} into #{self}, but that seems to not be possible"
                    elsif self_services.size > 1
                        raise Ambiguous, "merging #{self} and #{merged_task} is ambiguous: the #{self_names.join(", ")} data services could be used"
                    end

                    # "select" one service to use to handle other_name
                    target_service = self_services.pop
                    # set the argument
                    if arguments["#{target_service.name}_name"] != selected_source_name
                        arguments["#{target_service.name}_name"] = selected_source_name
                    end

                    # What we also need to do is map port names from the ports
                    # in +merged_task+ into the ports in +self+
                    #
                    # For that, we first build a name mapping and then we apply
                    # it by moving edges from +merged_task+ into +self+.
                    if DataServiceModel.needs_port_mapping?(other_service, target_service)
                        raise NotImplementedError, "mapping data flow ports is not implemented yet"
                    end
                end

                super
            end

            # Returns true if at least one port of the given service (designated
            # by its name) is connected to something.
            def using_data_service?(source_name)
                service = model.find_data_service(source_name)
                inputs  = service.each_input.map(&:name)
                outputs = service.each_output.map(&:name)

                each_source do |output|
                    description = output[self, Flows::DataFlow]
                    if description.any? { |(_, to), _| inputs.include?(to) }
                        return true
                    end
                end
                each_sink do |input, description|
                    if description.any? { |(from, _), _| outputs.include?(from) }
                        return true
                    end
                end
                false
            end

            # Finds the data sources on +other_task+ that have been selected
            # (i.e. the sources that have been assigned to a particular source
            # on the system). Yields it along with a data source on +self+ in
            # which it can be merged, either because the source is assigned as
            # well to the same device, or because it is not assigned yet
            def each_source_merge_candidate(other_task) # :nodoc:
                other_task.model.each_root_data_service do |name, other_service|
                    other_selection = other_task.selected_data_source(other_service)
                    next if !other_selection

                    self_selection = nil
                    available_services = model.each_data_service.find_all do |self_name, self_service|
                        self_selection = selected_data_source(self_service)

                        self_service.model == other_service.model &&
                            (!self_selection || self_selection == other_selection)
                    end

                    if self_selection != other_selection
                        yield(other_selection, other_service, available_services.map(&:last))
                    end
                end
            end

            extend ClassExtension
        end

        # Module that represents the device drivers in the task models. It
        # defines the methods that are available on task instances. For
        # methods that are available at the task model level, see
        # DataSource::ClassExtension
        module DataSource
            @name = "Orocos::RobyPlugin::DataSource"
            argument "com_bus"

            module ClassExtension
                # Enumerate all the data sources that are defined on this
                # component model
                def each_device(&block)
                    each_root_data_service.
                        find_all { |_, srv| srv.model < DataSource }.
                        map(&:last).
                        each(&block)
                end
            end

            # Enumerates the names of the devices that are tied to this
            # component
            def each_device_name
                if !block_given?
                    return enum_for(:each_device_name)
                end

                model.each_device do |srv|
                    device_name =
                        if srv.master?
                            arguments["#{srv.name}_name"]
                        else
                            arguments["#{srv.master.name}_name"]
                        end
                    yield(device_name) if device_name
                end
            end

            # Returns either the MasterDeviceInstance or SlaveDeviceInstance
            # that represents the device tied to this component.
            #
            # If +subname+ is given, it has to be the corresponding data service
            # name. It is optional only if there is only one device attached to
            # this component
            def robot_device(subname = nil)
                devices = model.each_device.to_a
                if !subname
                    if devices.empty?
                        raise ArgumentError, "#{self} does not handle any device"
                    elsif devices.size > 1
                        raise ArgumentError, "#{self} handles more than one device, you must specify one explicitely"
                    end
                else
                    devices = devices.find_all { |srv| srv.full_name == subname }
                    if devices.empty?
                        raise ArgumentError, "there is no device called #{subname} on #{self}"
                    end
                end
                device = devices.first

                device_name =
                    if device.master?
                        arguments["#{device.name}_name"]
                    else
                        arguments["#{device.master.name}_name"]
                    end
                return if !device_name

                description = robot.devices[device_name]
                if !description
                    raise ArgumentError, "there is no device called #{device_name} (selected for #{interface_name} on #{self})"
                end
                description
            end

            def bus_name
                if arguments[:bus_name]
                    arguments[:bus_name]
                else
                    roots = model.each_root_data_service.to_a
                    if roots.size == 1
                        roots.first.first
                    end
                end
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                triggering_devices = model.each_root_data_service.
                    find_all { |_, service| service.model < DataSource }.
                    map do |source_name, _|
                        device = robot.devices[arguments["#{source_name}_name"]]
                        if !device
                            RobyPlugin::Engine.warn "no device associated with #{source_name} (#{arguments["#{source_name}_name"]})"
                        end
                        device
                    end.compact

                if orogen_spec.activity_type !~ /(NonPeriodic|FileDescriptor)Activity/
                    triggering_devices.delete_if { |m| !m.com_bus }
                end

                triggering_devices.each do |device_instance|
                    service = device_instance.service
                    service.port_mappings.each do |service_port_name, port_name|
                        port = model.port(port_name)
                        # We don't care about input ports
                        next if !port.kind_of?(Orocos::Generation::OutputPort)
                        # We don't care about ports that aren't triggered by
                        # thsi device
                        next if !port.port_triggers.empty?

                        if device_instance.period
                            dynamics = (result[port_name] ||= PortDynamics.new(port.sample_size))
                            dynamics.add_trigger(device_instance.period, 1)
                            dynamics.add_trigger(
                                device_instance.period * device_instance.burst,
                                device_instance.burst)
                        end
                    end
                end

                result
            end

            include DataService

            @name = "DataSource"
            module ModuleExtension
                def to_s # :nodoc:
                    "#<DataSource: #{name}>"
                end

                def task_model
                    model = super
                    model.name = "#{name}DataSourceTask"
                    model
                end
            end
            extend ModuleExtension
        end

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBusDriver
            @name = "Orocos::RobyPlugin::ComBusDriver"
            # Communication busses are also device drivers
            include DataSource

            def self.to_s # :nodoc:
                "#<ComBusDriver: #{name}>"
            end

            def self.new_submodel(model, options = Hash.new)
                bus_options, options = Kernel.filter_options options,
                    :message_type => nil

                model = super(model, options)
                model.class_eval <<-EOD
                module ModuleExtension
                    def message_type
                        \"#{bus_options[:message_type]}\" || (super if defined? super)
                    end
                end
                extend ModuleExtension
                EOD
                model
            end

            # Finds out what output port serves what devices by looking at what
            # tasks it is connected.
            #
            # Indeed, for communication busses, the device model is determined
            # by the sink port of output connections.
            def each_connected_device(&block)
                if !block_given?
                    return enum_for(:each_connected_device)
                end

                each_concrete_output_connection do |source_port, sink_port, sink_task|
                    devices = sink_task.model.each_root_data_service.
                        find_all { |_, service| service.model < DataSource }.
                        map { |source_name, _| robot.devices[sink_task.arguments["#{source_name}_name"]] }.
                        compact.find_all { |device| device.com_bus }

                    yield(source_port, devices)
                end
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result = super
                end

                each_connected_device do |port, devices|
                    dynamics = PortDynamics.new(devices.map(&:sample_size).inject(&:+))
                    devices.each do |dev|
                        dynamics.add_trigger(dev.period, 1)
                        dynamics.add_trigger(dev.period * dev.burst, dev.burst)
                    end
                    result[port] = dynamics
                end

                result
            end

            # The output port name for the +bus_name+ device attached on this
            # bus
            def output_name_for(bus_name)
                bus_name
            end

            # The input port name for the +bus_name+ device attached on this bus
            def input_name_for(bus_name)
                "w#{bus_name}"
            end
        end
    end
end


