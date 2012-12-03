module Syskit
    module Models
        # Base type for data service models (DataService, Devices,
        # ComBus). Methods defined in this class are available on said
        # models (for instance Device.new_submodel)
        class DataServiceModel < Roby::TaskModelTag
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
                @orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project)
                super
            end

            # @!attribute rw parent_models
            #   @return [ValueSet<DataServiceModel>] the data service models
            #     that are parent of this one
            attribute(:parent_models) { ValueSet.new }

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

            # The model next in the ancestry chain, or nil if +self+ is root
            def supermodel
                ancestors = self.ancestors
                ancestors.shift
                ancestors.each do |m|
                    if m.respond_to?(:register_submodel)
                        return m
                    end
                end
                nil
            end

            # Creates a new DataServiceModel that is a submodel of +self+
            #
            # @param [Hash] options the option hash
            # @option options [String] :name the submodel name. Use this option
            #   only for "anonymous" models, i.e. models that won't be
            #   registered on a Ruby constant
            # @option options [Class] :type the type of the submodel. It must be
            #   DataServiceModel or one of its subclasses
            #
            def new_submodel(options = Hash.new, &block)
                options = Kernel.validate_options options,
                    :name => nil, :type => self.class

                model = options[:type].new
                register_submodel(model)
                if options[:name]
                    Syskit::Models.validate_model_name(options[:name])
                    model.name = options[:name].dup
                end

                model.provides self

                if block_given?
                    model.apply_block(&block)
                end

                # Now initialize the port_mappings hash. We register our own
                # ports as identity (from => from)
                self_mappings = (model.port_mappings[model] ||= Hash.new)
                model.each_input_port  { |port| self_mappings[port.name] = port.name }
                model.each_output_port { |port| self_mappings[port.name] = port.name }

                model
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
            #
            # If port mappings are given, they define the mapping between
            # ports in +service_model+ and existing ports in +self+
            def provides(service_model, new_port_mappings = Hash.new)
                # A device can provide either a device or a data service, but
                # not a combus. Idem for data service: only other data services
                # can be provided
                if !kind_of?(service_model.class)
                    raise ArgumentError, "a #{self.class.name} cannot provide a #{service_model.class.name}. If this is really what you mean, declare #{self.name} as a #{service_model.class.name} first"
                end

                if parent_models.include?(service_model)
                    return
                end

                service_model.each_port do |p|
                    if find_port(p.name)
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

                include service_model
                parent_models << service_model
            end

            # [Orocos::Spec::TaskContext] the object describing the data
            # service's interface
            attr_reader :orogen_model

            # [DataServiceModel] a task model that can be used to represent an
            # instance of this data service in a Roby plan
            def proxy_task_model
                if @proxy_task_model
                    return @proxy_task_model
                end
                @proxy_task_model = Syskit.proxy_task_model_for([self])
            end

            def pretty_print(pp)
                pp.text short_name
            end

            # Create a task instance that can be used in a plan to represent
            # this service
            #
            # The returned task instance is obviously an abstract one
            def instanciate(*args, &block)
                proxy_task_model.instanciate(*args, &block)
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
                if bus_options[:message_type]
                    if model.message_type && model.message_type != bus_options[:message_type]
                        raise ArgumentError, "cannot override message types. The current message type of #{name} is #{message_type}, which might come from another provided com bus"
                    elsif !model.message_type
                        model.message_type    = bus_options[:message_type]
                    end
                end
                if !bus_options[:message_type] && !model.message_type
                    raise ArgumentError, "com bus types must either have a message_type or provide another com bus type that does"
                end

                if attached_device_configuration_module
                    model.attached_device_configuration_module = Module.new
                    model.attached_device_configuration_module.include(attached_device_configuration_module)
                end
                model
            end

            def provides(service_model, new_port_mappings = Hash.new)
                if service_model.respond_to?(:message_type)
                    if message_type && message_type != service_model.message_type
                        raise ArgumentError, "#{self.name} cannot provide #{service_model.name} as their message type differs (resp. #{message_type} and #{service_model.message_type}"
                    end
                end

                super

                if service_model.respond_to?(:message_type) && !message_type
                    @message_type = service_model.message_type
                end
            end

            # If true, the com bus autoconnection code will override the
            # input port default policies to needs_reliable_connection
            #
            # It is true by default
            attr_predicate :override_policy?, true
            # [String] the name of the type used to communicate with the
            # supported components
            attr_accessor :message_type

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
                if attached_device_configuration_module
                    device_instance.extend(attached_device_configuration_module)
                end
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
                Models.validate_model_name(name)

                model = Syskit::DataService.new_submodel(&block)
                const_set(name, model)
                model
            end

            # Creates a new device model and register it on this module
            #
            # The returned value is an instance of DeviceModel in which
            # Device has been included.
            #
            def device_type(name, &block)
                Models.validate_model_name(name)

                model = Syskit::Device.new_submodel(&block)
                const_set(name, model)
                model
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
                Models.validate_model_name(name)

                model = Syskit::ComBus.new_submodel(options, &block)
                const_set(name, model)
                model
            end
        end
    end
end
Module.include Syskit::Models::ServiceModelsDefinitionDSL

