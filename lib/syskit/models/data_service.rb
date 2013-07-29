module Syskit
    module Models
        # Base type for data service models (DataService, Devices,
        # ComBus). Methods defined in this class are available on said
        # models (for instance Device.new_submodel)
        class DataServiceModel < Roby::Models::TaskServiceModel
            include Models::Base
            include Syskit::Models::PortAccess

            class << self
                # Each subclass of DataServiceModel maps to a "base" module that
                # all instances of DataServiceModel include.
                #
                # For instance, for DataServiceModel itself, it is DataService
                #
                # This attribute is the base module for this class of
                # DataServiceModel
                attr_accessor :base_module
            end

            def initialize
                clear_model
                super
            end

            def clear_model
                super
                @orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project)
                port_mappings.clear
            end

            # @!attribute rw port_mappings
            #   Port mappings from this service's parent models to the service
            #   itself
            #
            #   Whenever a data service provides another one, it is possible to
            #   specify that some ports of the provided service are mapped onto th
            #   ports of the new service. This hash keeps track of these port
            #   mappings.
            #
            #   The mapping is of the form
            #     
            #     [service_model, port] => target_port
            #
            #   @return [Hash<DataServiceModel,Hash<String,String>>] the
            #     mappings
            attribute(:port_mappings) { Hash.new }

            # The set of services that this service provides
            def each_fullfilled_model
                return enum_for(:each_fullfilled_model) if !block_given?
                ancestors.each do |m|
                    if m.kind_of?(DataServiceModel)
                        yield(m)
                    end
                end
            end

            def each_required_model
                return enum_for(:each_required_model) if !block_given?
                yield(self)
            end

            # Internal class used to apply configuration blocks to data
            # services. I.e. when one does
            #
            #   data_service_type 'Type' do
            #     input_port ...
            #   end
            #
            # The given block is applied on an instance of BlockInstanciator
            # that forwards the calls to, in order of preference, the interface
            # and then the service
            #
            # One should not use BlockInstanciator directly. Use
            # DataServiceModel#apply_block
            class BlockInstanciator < BasicObject
                attr_reader :name
                def initialize(model, name = nil)
                    @model = model
                    @name = name || model.name
                    @orogen_model = model.orogen_model

                    if !@orogen_model
                        raise InternalError, "no interface for #{model.short_name}"
                    end
                end

                def method_missing(m, *args, &block)
                    if @orogen_model.respond_to?(m)
                        @orogen_model.send(m, *args, &block)
                    else @model.send(m, *args, &block)
                    end
                end
            end

            # Applies a setup block on a service model
            #
            # If +name+ is given, that string will be reported as the service
            # name in the block, instead of the actual service name
            def apply_block(name = nil, &block)
                BlockInstanciator.new(self, name).instance_eval(&block)

                # Now initialize the port_mappings hash. We register our own
                # ports as identity (from => from)
                self_mappings = (port_mappings[self] ||= Hash.new)
                each_input_port  { |port| self_mappings[port.name] = port.name }
                each_output_port { |port| self_mappings[port.name] = port.name }
            end

            # Returns the set of port mappings needed between +service_type+ and
            # +self+
            #
            # In other words, if one wants to link port A from +service_type+ on
            # a task that provides a service of type +self+, it should actually
            # link to
            #
            #   actual_port_name = (port_mappings_for(service_type)['A'] || 'A')
            #
            # Raises ArgumentError if +self+ does not provide +service_type+
            def port_mappings_for(service_type)
                result = port_mappings[service_type]
                if !result
                    raise ArgumentError, "#{service_type.short_name} is not provided by #{short_name}"
                end
                result
            end

            # Declares that this data service model provides the given service
            # model
            #
            # If no port mappings are given, it will mean that the ports defined
            # by +service_model+ should be added to this service's interface.
            # If port mappings are given, they define the mapping between ports
            # in +service_model+ and existing ports in +self+
            #
            # Note that if both service_model and self have a port with the same
            # name, this port needs also to be mapped explicitely by providing
            # the 'name' => 'name' mapping in new_port_mappings
            def provides(service_model, new_port_mappings = Hash.new)
                # A device can provide either a device or a data service, but
                # not a combus. Idem for data service: only other data services
                # can be provided
                if !kind_of?(service_model.class)
                    raise ArgumentError, "a #{self.class.name} cannot provide a #{service_model.class.name}. If this is really what you mean, declare #{self.name} as a #{service_model.class.name} first"
                end

                if parent_models.include?(service_model)
                    return
                elsif !service_model.kind_of?(DataServiceModel) # this is probably just a task service
                    return super(service_model)
                end

                service_model.each_port do |p|
                    if find_port(p.name) && !new_port_mappings[p.name]
                        raise SpecError, "port collision: #{self} and #{service_model} both have a port named #{p.name}. If you mean to tell syskit that this is the same port, you must provide the mapping explicitely by adding '#{p.name}' => '#{p.name}' to the provides statement"
                        new_port_mappings[p.name] ||= p.name
                    end
                end

                new_port_mappings.each do |service_name, self_name|
                    if !(source_port = service_model.find_port(service_name))
                        raise SpecError, "#{service_name} is not a port of #{service_model.short_name}"
                    end
                    if !(target_port = find_port(self_name))
                        raise SpecError, "#{self_name} is not a port of #{short_name}"
                    end
                    if target_port.type != source_port.type
                        raise SpecError, "invalid port mapping #{service_name} => #{self_name} in #{self.short_name}.provides(#{service_model.short_name}): port #{source_port.name} on #{self.short_name} is of type #{source_port.type.name} and #{target_port.name} on #{service_model.short_name} is of type #{target_port.type.name}"
                    elsif source_port.class != target_port.class
                        raise SpecError, "invalid port mapping #{service_name} => #{self_name} in #{self.short_name}.provides(#{service_model.short_name}): port #{source_port.name} on #{self.short_name} is a #{target_port.class.name} and #{target_port.name} on #{service_model.short_name} is of a #{source_port.class.name}"
                    end
                end

                service_model.port_mappings.each do |original_service, mappings|
                    updated_mappings = Hash.new
                    mappings.each do |from, to|
                        updated_mappings[from] = new_port_mappings[to] || to
                    end
                    port_mappings[original_service] =
                        Models.merge_port_mappings(port_mappings[original_service] || Hash.new, updated_mappings)
                end

                # Now, add the ports that are going to be created because of the
                # addition of the service
                service_model.each_port do |p|
                    new_port_mappings[p.name] ||= p.name
                end
                port_mappings[service_model] =
                    Models.merge_port_mappings(port_mappings[service_model] || Hash.new, new_port_mappings)

                # Merging the interface should never raise at this stage. It
                # should have been validated above.
                Models.merge_orogen_task_context_models(orogen_model, [service_model.orogen_model], new_port_mappings)

                # For completeness, add port mappings for ourselves
                port_mappings[self] = Hash.new
                each_port do |p|
                    port_mappings[self][p.name] = p.name
                end

                super(service_model)
            end

            # [Orocos::Spec::TaskContext] the object describing the data
            # service's interface
            attr_reader :orogen_model

            # A task model that can be used to represent an
            # instance of this data service in a Roby plan
            #
            # @return [Model<TaskContext>]
            def proxy_task_model
                if @proxy_task_model
                    return @proxy_task_model
                end
                @proxy_task_model = Syskit.proxy_task_model_for([self])
            end

            # Create a task that can be used as a placeholder for #self in the
            # plan
            #
            # @return [TaskContext]
            def create_proxy_task
                proxy_task_model.new
            end

            def to_component_model; self end

            # Create a task instance that can be used in a plan to represent
            # this service
            #
            # The returned task instance is obviously an abstract one
            #
            # @return [TaskContext]
            def instanciate(plan, context = DependencyInjectionContext.new, options = Hash.new, &block)
                proxy_task_model.instanciate(plan, context, options, &block)
            end

            def pretty_print(pp)
                pp.text short_name
            end

            def to_dot(io)
                id = object_id.abs
                inputs = orogen_model.all_input_ports.map(&:name)
                outputs = orogen_model.all_output_ports.map(&:name)
                label = Graphviz.dot_iolabel(constant_name, inputs, outputs)
                io << "  C#{id} [label=\"#{label}\",fontsize=15];"

                parent_models.each do |parent_m|
                    parent_id = parent_m.object_id.abs
                    (parent_m.each_input_port.to_a + parent_m.each_output_port.to_a).
                        each do |parent_p|
                        io << "  C#{parent_id}:#{parent_p.name} -> C#{id}:#{port_mappings_for(parent_m)[parent_p.name]};"
                    end

                end
            end

            def as_plan
                to_instance_requirements.as_plan
            end
        end

        # Metamodel for all devices
        class DeviceModel < DataServiceModel
            def new_submodel(options = Hash.new, &block)
                model = super(options, &block)
                if device_configuration_module
                    model.device_configuration_module = Module.new
                    model.device_configuration_module.include(device_configuration_module)
                end
                model
            end

            attribute(:device_configuration_module)

            # Requires that the given block is used to add methods to the
            # device configuration objects.
            #
            # I.e. if a device type is defined with
            #    device_type('Hokuyo').
            #       extend_device_configuration do
            #           def enable_remanence_values; @remanence = true; self end
            #           def remanence_values_enabled?; @remanence end
            #       end
            #
            # Then the methods are made available on the corresponding
            # MasterDeviceInstance instances:
            #
            #   Robot.devices do
            #     device(Devices::Hokuyo).
            #       enable_remanence_values
            #   end
            #
            def extend_device_configuration(&block)
                if block
                    self.device_configuration_module ||= Module.new
                    device_configuration_module.class_eval(&block)
                end
                self
            end

            # Applies the configuration extensions declaredwith
            # #extend_device_configuration to the provided class
            def apply_device_configuration_extensions(device_instance)
                if device_configuration_module
                    device_instance.extend(device_configuration_module)
                end
            end

            def provides(service_model, new_port_mappings = Hash.new)
                super

                # If the provided model has a device_configuration_module,
                # include it in our own
                if service_model.respond_to?(:device_configuration_module) &&
                    service_model.device_configuration_module
                    self.device_configuration_module ||= Module.new
                    self.device_configuration_module.include(service_model.device_configuration_module)
                end
            end
        end

        # Metamodel for all communication busses
        class ComBusModel < DeviceModel
            def initialize(*args, &block)
                super
                @override_policy = true
            end

            attr_reader :bus_base_srv
            attr_reader :bus_in_srv
            attr_reader :bus_out_srv
            attr_reader :bus_srv

            attr_reader :client_in_srv
            attr_reader :client_out_srv
            attr_reader :client_srv

            # Creates a new submodel of this communication bus model
            #
            # @param [Hash] options the configuration options. See
            #   DataServiceModel#provides for the list of options from data
            #   services
            # @option options [Boolean] :override_policy if true (the default),
            #   the communication bus handling will mark the associated component's
            #   input ports as needs_reliable_connection so that relevant
            #   policies are chosen.
            # @option options [String] :message_type the type name of the
            #   type that is used by this combus to communicate with the
            #   components it supports
            def new_submodel(options = Hash.new, &block)
                bus_options, options = Kernel.filter_options options,
                    :override_policy => override_policy?, :message_type => message_type

                model = super(options, &block)
                model.override_policy = bus_options[:override_policy]
                if !bus_options[:message_type] && !model.message_type
                    raise ArgumentError, "com bus types must either have a message_type or provide another com bus type that does"
                elsif bus_options[:message_type] && model.message_type
                    if model.message_type != bus_options[:message_type]
                        raise ArgumentError, "cannot override message types. The current message type of #{name} is #{message_type}, which might come from another provided com bus"
                    end
                elsif !model.message_type
                    model.message_type = bus_options[:message_type]
                end

                model.attached_device_configuration_module.include(attached_device_configuration_module)
                model
            end

            # The name of the bus_in_srv dynamic service defined on driver tasks
            def dynamic_service_name
                name = "com_bus"
                if self.name
                    name = "#{name}_#{self.name}"
                end
                name
            end

            def included(mod)
                if mod <= Syskit::Component
                    # declare the relevant dynamic service
                    combus_m = self
                    dyn_name = dynamic_service_name
                    bus_srv  = bus_base_srv
                    mod.dynamic_service bus_base_srv, :as => dynamic_service_name do
                        options = Kernel.validate_options self.options, :direction => nil
                        in_name =
                            if in_srv = mod.find_data_service_from_type(combus_m.bus_in_srv)
                                in_srv.port_mappings_for_task['to_bus']
                            else
                                combus_m.input_name_for(name)
                            end

                        if options[:direction] == 'inout'
                            provides combus_m.bus_srv, 'from_bus' => combus_m.output_name_for(name),
                                'to_bus' => in_name
                        elsif options[:direction] == 'in'
                            provides combus_m.bus_in_srv, 'to_bus' => in_name
                        elsif options[:direction] == 'out'
                            provides combus_m.bus_out_srv, 'from_bus' => combus_m.output_name_for(name)
                        else raise ArgumentError, "invalid :direction option given, expected 'in', 'out' or 'inout' and got #{options[:direction]}"
                        end
                    end
                end
            end

            def provides(service_model, new_port_mappings = Hash.new)
                if service_model.respond_to?(:message_type)
                    if message_type && service_model.message_type && message_type != service_model.message_type
                        raise ArgumentError, "#{self.name} cannot provide #{service_model.name} as their message type differs (resp. #{message_type} and #{service_model.message_type}"
                    end
                end

                super

                if service_model.respond_to?(:message_type) && !message_type
                    @message_type = service_model.message_type
                    @bus_base_srv   = service_model.bus_base_srv
                    @bus_in_srv     = service_model.bus_in_srv
                    @bus_out_srv    = service_model.bus_out_srv
                    @bus_srv        = service_model.bus_srv
                    @client_in_srv  = service_model.client_in_srv
                    @client_out_srv = service_model.client_out_srv
                    @client_srv     = service_model.client_srv
                end
            end

            # If true, the com bus autoconnection code will override the
            # input port default policies to needs_reliable_connection
            #
            # It is true by default
            attr_predicate :override_policy?, true

            # The name of the type used to communicate with the supported
            # components
            #
            # @return [String]
            attr_reader :message_type

            def message_type=(message_type)
                @message_type = message_type
                @bus_base_srv = data_service_type 'BusBaseSrv'
                @bus_in_srv  = data_service_type('BusInSrv') { input_port 'to_bus', message_type }
                @bus_out_srv = data_service_type('BusOutSrv') { output_port 'from_bus', message_type }
                @bus_srv     = data_service_type 'BusSrv'

                bus_in_srv.provides bus_base_srv
                bus_out_srv.provides bus_base_srv
                bus_srv.provides bus_in_srv
                bus_srv.provides bus_out_srv

                @client_in_srv  = data_service_type('ClientInSrv') { input_port 'from_bus', message_type }
                @client_out_srv = data_service_type('ClientOutSrv') { output_port 'to_bus', message_type }
                @client_srv     = data_service_type 'ClientSrv'
                client_srv.provides client_in_srv
                client_srv.provides client_out_srv
            end

            attribute(:attached_device_configuration_module) { Module.new }

            # Requires that the given block is used to add methods to the
            # device configuration objects.
            #
            # I.e. if a combus type is defined with
            #    com_bus_type('canbus').
            #       extend_attached_device_configuration do
            #           def can_id(id, mask)
            #               @id, @mask = id, mask
            #           end
            #       end
            #
            # Then the #can_id method will be available on device instances
            # that are attached to a canbus device
            #
            #   device(Type).attach_to(can).can_id(0x10, 0x10)
            #
            def extend_attached_device_configuration(&block)
                if block
                    attached_device_configuration_module.class_eval(&block)
                end
                self
            end

            # Applies the configuration extensions declaredwith
            # #extend_device_configuration to the provided class
            def apply_attached_device_configuration_extensions(device_instance)
                device_instance.extend(attached_device_configuration_module)
            end

            # The name of the port that will send data from the bus to the
            # device of the given name
            def output_name_for(device_name)
                device_name
            end

            # The name of the port that will receive data from the device of the
            # given name to the bus
            def input_name_for(device_name)
                "w#{device_name}"
            end
        end


        # This module is used to define the methods that allow to define
        # module-based models (data services and friends) on Module
        module ServiceModelsDefinitionDSL
            # Creates a new data service model and register it on this module
            #
            # If a block is given, it is used to declare the service's
            # interface, i.e. the input and output ports that are needed on any
            # task that provides this source.
            #
            # @return [DataServiceModel] the created model
            def data_service_type(name, &block)
                MetaRuby::ModelAsModule.create_and_register_submodel(self, name, Syskit::DataService, &block)
            end

            # Creates a new device model and register it on this module
            #
            # The returned value is an instance of DeviceModel in which
            # Device has been included.
            #
            def device_type(name, &block)
                MetaRuby::ModelAsModule.create_and_register_submodel(self, name, Syskit::Device, &block)
            end

            # Creates a new communication bus model
            #
            # It accepts the same arguments than device_type. In addition, the
            # 'message_type' option must be used to specify what data type is
            # used to represent the bus messages:
            #
            #   com_bus 'can', :message_type => '/can/Message'
            #
            # The returned value is an instance of DataServiceModel, in which
            # ComBus is included.
            def com_bus_type(name, options = Hash.new, &block)
                MetaRuby::ModelAsModule.create_and_register_submodel(self, name, Syskit::ComBus, options, &block)
            end
        end
    end
end
Module.include Syskit::Models::ServiceModelsDefinitionDSL

