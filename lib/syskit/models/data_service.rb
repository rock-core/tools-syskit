# frozen_string_literal: true

module Syskit
    module Models
        # Base type for data service models (DataService, Devices,
        # ComBus). Methods defined in this class are available on said
        # models (for instance Device.new_submodel)
        class DataServiceModel < Roby::Models::TaskServiceModel
            include Models::Base
            include MetaRuby::DSLs::FindThroughMethodMissing
            include Syskit::Models::PortAccess

            # Create a model that is root for a model hierarchy
            #
            # This is used to create e.g. Syskit::DataService
            #
            # The result of this method must be assigned to a constant. It is
            # marked as permanent w.r.t. MetaRuby's model management.
            def self.new_permanent_root(parent: nil)
                model = new(project: OroGen::Spec::Project.blank)
                model.root = true
                model.permanent_model = true
                model.provides(parent) if parent
                model
            end

            def initialize(project: Roby.app.default_orogen_project)
                @orogen_model = OroGen::Spec::TaskContext.new(project)
                super()
            end

            def match
                Queries::DataServiceMatcher.new(
                    Queries::ComponentMatcher.new.with_model(self)
                ).with_model(self)
            end

            def clear_model
                super()
                @orogen_model = OroGen::Spec::TaskContext.new(@orogen_model.project)
                port_mappings.clear
            end

            # Optional dependency injection
            #
            # Returns an {InstanceRequirements} that you can use to inject
            # optional dependencies that will be fullfilled only if there is
            # already a matching task deployed in the plan
            #
            # This can only be meaningfully used when injected for a
            # composition's optional child
            #
            # @return [InstanceRequirements]
            def if_already_present
                to_instance_requirements.if_already_present
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
            #     provided_service_model => [provided_service_model_port, port]
            #
            #   @return [Hash<DataServiceModel,Hash<String,String>>] the
            #     mappings
            attribute(:port_mappings) do
                {}
            end

            # The set of services that this service provides
            def each_fullfilled_model
                return enum_for(:each_fullfilled_model) unless block_given?

                ancestors.each do |m|
                    yield(m) if m.kind_of?(DataServiceModel)
                end
            end

            def each_required_model
                return enum_for(:each_required_model) unless block_given?

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
                    unless model.orogen_model
                        raise InternalError, "no interface for #{model.short_name}"
                    end

                    @model = model
                    @name = name || model.name
                    @orogen_model = model.orogen_model
                end

                def respond_to_missing?(m, _include_private)
                    @orogen_model.respond_to?(m) ||
                        @model.respond_to?(m)
                end

                ruby2_keywords def method_missing(m, *args, &block) # rubocop:disable Style/MethodMissingSuper, Style/MissingRespondToMissing
                    if @orogen_model.respond_to?(m)
                        @orogen_model.public_send(m, *args, &block)
                    else
                        @model.public_send(m, *args, &block)
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
                self_mappings = (port_mappings[self] ||= {})
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
            # @raise [ArgumentError] if self does not provide service_type
            def port_mappings_for(service_type)
                unless (result = port_mappings[service_type])
                    raise ArgumentError, "#{service_type.short_name} is not "\
                                         "provided by #{short_name}"
                end

                result
            end

            # Tests whether self already provides another service
            #
            # @param [Model<DataService>]
            def provides?(srv)
                parent_models.include?(srv)
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
            def provides(service_model, new_port_mappings = {})
                # A device can provide either a device or a data service, but
                # not a combus. Idem for data service: only other data services
                # can be provided
                unless kind_of?(service_model.class)
                    raise ArgumentError,
                          "a #{self.class.name} cannot provide a "\
                          "#{service_model.class.name}. If this is really "\
                          "what you mean, declare #{name} as a "\
                          "#{service_model.class.name} first"
                end

                return if parent_models.include?(service_model)
                # this is probably just a Roby task service
                unless service_model.kind_of?(DataServiceModel)
                    return super(service_model)
                end

                service_model.each_port do |p|
                    if find_port(p.name) && !new_port_mappings[p.name]
                        raise SpecError,
                              "port collision: #{self} and #{service_model} both "\
                              "have a port named #{p.name}. If you mean to tell "\
                              "syskit that this is the same port, you must provide "\
                              "the mapping explicitely by adding "\
                              "'#{p.name}' => '#{p.name}' to the provides statement"
                    end
                end

                new_port_mappings.each do |service_name, self_name|
                    unless (source_port = service_model.find_port(service_name))
                        raise SpecError,
                              "#{service_name} is not a port of "\
                              "#{service_model.name}"
                    end
                    unless (target_port = find_port(self_name))
                        raise SpecError,
                              "#{self_name} is not a port of #{name}"
                    end
                    if target_port.type != source_port.type
                        raise SpecError,
                              "invalid port mapping #{service_name} => #{self_name} in "\
                              "#{name}.provides("\
                              "#{service_model.name}): port #{source_port.name} "\
                              "on #{name} is of type "\
                              "#{source_port.type.name} and #{target_port.name} on "\
                              "#{service_model.name} is of type "\
                              "#{target_port.type.name}"
                    elsif source_port.class != target_port.class
                        raise SpecError,
                              "invalid port mapping #{service_name} => #{self_name} in "\
                              "#{name}.provides("\
                              "#{service_model.name}): port #{source_port.name} "\
                              "on #{name} is a #{target_port.class.name} "\
                              "and #{target_port.name} on #{service_model.name} "\
                              "is of a #{source_port.class.name}"
                    end
                end

                service_model.port_mappings.each do |original_service, mappings|
                    updated_mappings = {}
                    mappings.each do |from, to|
                        updated_mappings[from] = new_port_mappings[to] || to
                    end
                    port_mappings[original_service] =
                        Models.merge_port_mappings(
                            port_mappings[original_service] || {}, updated_mappings
                        )
                end

                # Now, add the ports that are going to be created because of the
                # addition of the service
                service_model.each_port do |p|
                    new_port_mappings[p.name] ||= p.name
                end
                port_mappings[service_model] =
                    Models.merge_port_mappings(
                        port_mappings[service_model] || {}, new_port_mappings
                    )

                # Merging the interface should never raise at this stage. It
                # should have been validated above.
                Models.merge_orogen_task_context_models(
                    orogen_model, [service_model.orogen_model], new_port_mappings
                )

                # For completeness, add port mappings for ourselves
                port_mappings[self] = {}
                each_port do |p|
                    port_mappings[self][p.name] = p.name
                end

                super(service_model)
            end

            # [Orocos::Spec::TaskContext] the object describing the data
            # service's interface
            attr_reader :orogen_model

            # @deprecated use {#placeholder_model} instead
            def proxy_task_model
                Roby.warn_deprecated "DataService.proxy_task_model is deprecated, "\
                                     "use .placeholder_model instead"
                placeholder_model
            end

            # @deprecated use {#create_placeholder_task} instead
            def create_proxy_task
                Roby.warn_deprecated "DataService.create_proxy_task is deprecated, "\
                                     "use .create_placeholder_task instead"
                create_placeholder_task
            end

            # Create a task that can be used as a placeholder for #self in the
            # plan
            #
            # @see Placeholder
            # @return [Component]
            def create_placeholder_task
                placeholder_model.new
            end

            # A component model that can be used to represent an instance of
            # this data service in a Roby plan
            #
            # @see Placeholder
            # @return [Component]
            def placeholder_model
                @placeholder_model ||= Placeholder.for([self])
            end

            # Wether this model represents a placeholder for data services
            #
            # @see Placeholder
            def placeholder?
                false
            end

            def to_component_model
                self
            end

            # Delegated call from {Port#connected?}
            #
            # Always returns false as "plain" data service ports cannot be
            # connected
            def connected?(_out_port, _in_port)
                false
            end

            # Create a task instance that can be used in a plan to represent
            # this service
            #
            # The returned task instance is obviously an abstract one
            #
            # @return [TaskContext]
            def instanciate(
                plan, context = DependencyInjectionContext.new, **options, &block
            )
                placeholder_model.instanciate(plan, context, **options, &block)
            end

            def pretty_print(pp)
                pp.text short_name
            end

            # Try to bind the data service model on the given task
            #
            # @param [Syskit::Component] component
            # @return [nil,BoundDataService]
            def try_bind(component)
                component.find_data_service_from_type(self)
            rescue AmbiguousServiceSelection # rubocop:disable Lint/SuppressedException
            end

            # Binds the data service model on the given task
            #
            # @param [Syskit::Component] component
            # @return [nil,BoundDataService]
            # @raise [ArgumentError] if the given component has no such data
            #   service, or if it has more than one
            def bind(component)
                unless (bound = try_bind(component))
                    raise ArgumentError, "cannot bind #{self} to #{component}"
                end

                bound
            end

            # @deprecated use {#try_bind} instead
            def try_resolve(task)
                Roby.warn_deprecated "#{__method__} is deprecated, use #try_bind instead"
                try_bind(task)
            end

            # @deprecated use {#bind} instead
            def resolve(task)
                Roby.warn_deprecated "#{__method__} is deprecated, use #bind instead"
                bind(task)
            end

            def to_dot(io)
                id = object_id.abs
                inputs = orogen_model.all_input_ports.map(&:name)
                outputs = orogen_model.all_output_ports.map(&:name)
                label = Graphviz.dot_iolabel(constant_name, inputs, outputs)
                io << "  C#{id} [label=\"#{label}\",fontsize=15];"

                parent_models.each do |parent_m|
                    parent_id = parent_m.object_id.abs
                    (parent_m.each_input_port.to_a + parent_m.each_output_port.to_a)
                        .each do |parent_p|
                            io << "  C#{parent_id}:#{parent_p.name} -> "\
                                  "C#{id}:#{port_mappings_for(parent_m)[parent_p.name]};"
                        end
                end
            end

            def as_plan
                to_instance_requirements.as_plan
            end
        end

        # Metamodel for all devices
        class DeviceModel < DataServiceModel
            def setup_submodel(submodel, **options, &block)
                super

                if device_configuration_module
                    submodel.device_configuration_module = Module.new
                    submodel.device_configuration_module
                            .include(device_configuration_module)
                end

                nil
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

                nil
            end

            def provides(service_model, new_port_mappings = {})
                super

                # If the provided model has a device_configuration_module,
                # include it in our own
                if service_model.respond_to?(:device_configuration_module) &&
                   service_model.device_configuration_module
                    self.device_configuration_module ||= Module.new
                    self.device_configuration_module
                        .include(service_model.device_configuration_module)
                end
            end

            def find_all_drivers
                # Since we want to drive a particular device, we actually need a
                # concrete task model. So, search for one.
                #
                # Get all task models that implement this device
                Syskit::Component
                    .each_submodel
                    .find_all { |t| t.fullfills?(self) && !t.abstract? }
            end

            def default_driver
                tasks = find_all_drivers
                if tasks.size > 1
                    raise Ambiguous,
                          "#{tasks.map(&:to_s).join(', ')} can all handle '#{self}'"
                elsif tasks.empty?
                    raise ArgumentError, "no task can handle devices of type '#{self}'"
                end

                tasks.first
            end
        end

        # Metamodel for all communication busses
        class ComBusModel < DeviceModel
            def initialize(project: Roby.app.default_orogen_project, &block)
                super
                @override_policy = true
            end

            # Returns whether this bus clients receive messages from the bus
            def client_to_bus?
                client_out_srv
            end

            # Retursn whether this bus clients send messages to the bus
            def bus_to_client?
                client_in_srv
            end

            attr_reader :bus_base_srv
            attr_reader :bus_in_srv
            attr_reader :bus_out_srv
            attr_reader :bus_srv

            attr_reader :client_in_srv
            attr_reader :client_out_srv
            attr_reader :client_srv

            attr_predicate :lazy_dispatch?, true

            # Creates a new submodel of this communication bus model
            #
            # @param [Hash] options the configuration options. See
            #   DataServiceModel#provides for the list of options from data
            #   services
            # @param [Boolean] lazy_dispatch whether the dynamic services used
            #   to attach the devices should be all instanciated at the beginning
            #   (the default) or only on-demand
            # @param [Boolean] override_policy if true (the default),
            #   the communication bus handling will mark the associated component's
            #   input ports as needs_reliable_connection so that relevant
            #   policies are chosen.
            # @param [String,Model<Type>] message_type the type name of the
            #   type that is used by this combus to communicate with the
            #   components it supports
            def new_submodel(
                lazy_dispatch: false, override_policy: override_policy?,
                message_type: self.message_type, **options, &block
            )
                super
            end

            def setup_submodel(
                model,
                lazy_dispatch: false, override_policy: override_policy?,
                message_type: self.message_type, **options, &block
            )
                if message_type.respond_to?(:to_str)
                    message_type = Roby.app.default_loader.resolve_type(message_type)
                end
                super(model, **options, &block)

                model.lazy_dispatch   = lazy_dispatch
                model.override_policy = override_policy
                if !message_type && !model.message_type
                    raise ArgumentError,
                          "com bus types must either have a message_type or provide "\
                          "another com bus type that does"
                elsif message_type && model.message_type
                    if message_type != model.message_type
                        raise ArgumentError,
                              "cannot override message types. The current message type "\
                              "of #{model.name} is #{model.message_type}, which "\
                              "might come from another provided com bus"
                    end
                elsif !model.message_type
                    model.message_type = message_type
                end

                model.attached_device_configuration_module
                     .include(attached_device_configuration_module)
            end

            def clear_model
                super
                @message_type = nil
            end

            # The name of the bus_in_srv dynamic service defined on driver tasks
            def dynamic_service_name
                name = "com_bus"
                name = "#{name}_#{self.name}" if self.name
                name
            end

            def included(mod)
                return unless mod <= Syskit::Component

                # declare the relevant dynamic service
                combus_m = self
                mod.dynamic_service bus_base_srv, as: dynamic_service_name do
                    options = Kernel.validate_options self.options, client_to_bus: nil,
                                                                    bus_to_client: nil
                    in_srv = mod.find_data_service_from_type(combus_m.bus_in_srv)
                    in_name =
                        if in_srv
                            in_srv.port_mappings_for_task["to_bus"]
                        else
                            combus_m.input_name_for(name)
                        end

                    out_srv = mod.find_data_service_from_type(combus_m.bus_out_srv)
                    out_name =
                        if out_srv
                            out_srv.port_mappings_for_task["from_bus"]
                        else
                            combus_m.output_name_for(name)
                        end

                    begin
                        client_to_bus = options.fetch(:client_to_bus)
                        bus_to_client = options.fetch(:bus_to_client)
                    rescue KeyError
                        raise ArgumentError, "you must provide both the client_to_bus "\
                                             "and bus_to_client option when "\
                                             "instanciating a com bus dynamic service"
                    end

                    if client_to_bus && bus_to_client
                        provides combus_m.bus_srv, "from_bus" => out_name,
                                                   "to_bus" => in_name
                        component_model.orogen_model
                                       .find_port(in_name)
                                       .needs_reliable_connection
                    elsif client_to_bus
                        provides combus_m.bus_in_srv, "to_bus" => in_name
                        component_model.orogen_model
                                       .find_port(in_name)
                                       .needs_reliable_connection
                    elsif bus_to_client
                        provides combus_m.bus_out_srv, "from_bus" => out_name
                    else
                        raise ArgumentError, "at least one of bus_to_client or "\
                                             "client_to_bus must be true"
                    end
                end
            end

            def provides(service_model, new_port_mappings = {})
                if service_model.respond_to?(:message_type)
                    if message_type && service_model.message_type &&
                       (message_type != service_model.message_type)
                        raise ArgumentError,
                              "#{name} cannot provide #{service_model.name} "\
                              "as their message type differs (resp. #{message_type} "\
                              "and #{service_model.message_type}"
                    end
                end

                super

                return unless service_model.respond_to?(:message_type) && !message_type

                @message_type   = service_model.message_type
                @bus_base_srv   = service_model.bus_base_srv
                @bus_in_srv     = service_model.bus_in_srv
                @bus_out_srv    = service_model.bus_out_srv
                @bus_srv        = service_model.bus_srv
                @client_in_srv  = service_model.client_in_srv
                @client_out_srv = service_model.client_out_srv
                @client_srv     = service_model.client_srv
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
                @bus_base_srv = data_service_type "BusBaseSrv"
                @bus_in_srv = data_service_type("BusInSrv") do
                    input_port "to_bus", message_type
                end
                @bus_out_srv = data_service_type("BusOutSrv") do
                    output_port "from_bus", message_type
                end
                @bus_srv = data_service_type "BusSrv"

                bus_in_srv.provides bus_base_srv
                bus_out_srv.provides bus_base_srv
                bus_srv.provides bus_in_srv
                bus_srv.provides bus_out_srv

                @client_in_srv = data_service_type("ClientInSrv") do
                    input_port "from_bus", message_type
                end
                @client_out_srv = data_service_type("ClientOutSrv") do
                    output_port "to_bus", message_type
                end
                @client_srv = data_service_type "ClientSrv"
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
                attached_device_configuration_module.class_eval(&block) if block
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
            def data_service_type(name, parent: Syskit::DataService, &block)
                model = MetaRuby::ModelAsModule.create_and_register_submodel(
                    self, name, parent, &block
                )
                model.doc(
                    MetaRuby::DSLs.parse_documentation_block(/.*/, "data_service_type")
                )
                model
            end

            # Creates a new device model and register it on this module
            #
            # The returned value is an instance of DeviceModel in which
            # Device has been included.
            #
            def device_type(name, parent: Syskit::Device, &block)
                model = MetaRuby::ModelAsModule.create_and_register_submodel(
                    self, name, parent, &block
                )
                model.doc(
                    MetaRuby::DSLs.parse_documentation_block(/.*/, "device_type")
                )
                model
            end

            # Creates a new communication bus model
            #
            # It accepts the same arguments than device_type. In addition, the
            # 'message_type' option must be used to specify what data type is
            # used to represent the bus messages:
            #
            #   com_bus 'can', message_type: '/can/Message'
            #
            # The returned value is an instance of DataServiceModel, in which
            # ComBus is included.
            def com_bus_type(name, parent: Syskit::ComBus, **options, &block)
                model = MetaRuby::ModelAsModule.create_and_register_submodel(
                    self, name, parent, **options, &block
                )
                model.doc MetaRuby::DSLs.parse_documentation_block(/.*/, "com_bus_type")
                model
            end
        end
    end
end
Module.include Syskit::Models::ServiceModelsDefinitionDSL
