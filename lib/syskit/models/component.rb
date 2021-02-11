# frozen_string_literal: true

module Syskit
    module Models
        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module Component
            include Models::Base
            include MetaRuby::ModelAsClass
            include Syskit::DataService

            def to_component_model
                self
            end

            # Method that maps data services from this component's parent models
            # to this composition's own
            #
            # It is called as needed when calling {#each_data_service}
            def promote_data_service(_full_name, service)
                service.attach(self, verify: false)
            end

            # The data services defined on this task, as a mapping from the data
            # service full name to the BoundDataService object.
            #
            # @key_name full_name
            # @return [Hash<String,BoundDataService>]
            inherited_attribute(:data_service, :data_services, map: true) { {} }

            # List of modules that should be applied on the underlying
            # {Orocos::RubyTasks::StubTaskContext} when running tests in
            # non-stub mode
            #
            # @see stub
            #
            # @return [Array<Module>]
            inherited_attribute(:stub_module, :stub_modules) { [Module.new] }

            def clear_model
                super
                data_services.clear
                dynamic_services.clear
                # Note: the placeholder_models cache is cleared separately. The
                # reason is that we need to clear it on permanent and
                # non-permanent models alike, including component models that
                # are defined in syskit. The normal procedure is to call
                # #clear_model only on the models defined in the app(s)
            end

            # Enumerate all the devices that are defined on this
            # component model
            #
            # @yieldparam [Model<Device>] device_model
            # @return [void]
            def each_master_driver_service
                return enum_for(:each_master_driver_service) unless block_given?

                each_root_data_service do |srv|
                    yield(srv) if srv.model < Syskit::Device
                end
            end

            # Enumerate all the combus that are defined on this
            # component model
            #
            # @yield [Model<ComBus>] com_bus_model
            # @return [void]
            def each_com_bus_driver_service
                return enum_for(:each_com_bus_driver_service) unless block_given?

                each_root_data_service do |srv|
                    yield(srv) if srv.model < Syskit::ComBus
                end
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
                matching_services = find_all_services_from_type(target_model)

                if pattern # match by name too
                    # Find the selected service. There can be shortcuts, so
                    # for instance bla.left would be able to select both the
                    # 'left' main service or the 'bla.blo.left' slave
                    # service.
                    rx = /(^|\.)#{pattern}$/
                    matching_services.delete_if { |service| service.full_name !~ rx }
                end
                return matching_services.first if matching_services.size <= 1

                master_matching_services = matching_services.find_all(&:master?)
                if master_matching_services.size == 1
                    return master_matching_services.first
                end

                pattern_msg += " matching name hint #{pattern}" if pattern
                raise AmbiguousServiceSelection.new(
                    self, target_model, master_matching_services
                ), "there is more than one service of type #{target_model.name} "\
                   "in #{name}#{pattern_msg}"
            end

            # Define a module that should be applied on the underlying
            # {Orocos::RubyTasks::StubTaskContext} when running tests in
            # non-live mode
            def stub(&block)
                stub_modules.first.class_eval(&block)
            end

            # Apply what's necessary for this component (from the underlying
            # component implementation) to be a proper component stub
            def prepare_stub(component)
                stub_modules = each_stub_module.to_a
                stub_modules.each do |m|
                    component.orocos_task.extend m
                end
            end

            # Checks if a given component implementation needs to be stubbed
            def needs_stub?(_component)
                false
            end

            # Enumerates all services that are slave (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_slave_data_service(master_service)
                unless block_given?
                    return enum_for(:each_slave_data_service, master_service)
                end

                each_data_service(nil) do |_name, service|
                    next unless (m = service.master)

                    yield(service) if m.full_name == master_service.full_name
                end
            end

            # Enumerates all services that are root (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_root_data_service
                return enum_for(:each_root_data_service) unless block_given?

                each_data_service(nil) do |_name, service|
                    yield(service) if service.master?
                end
            end

            # Generic instanciation of a component.
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the plan and returns it.
            def instanciate(
                plan, _context = DependencyInjectionContext.new,
                task_arguments: {}, **
            )
                plan.add(task = new(**task_arguments))
                task
            end

            # The model next in the ancestry chain, or nil if +self+ is root
            def supermodel
                superclass if superclass.respond_to?(:register_submodel)
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.with_arguments(special_behaviour: true))
            #
            def with_arguments(**arguments)
                InstanceRequirements.new([self]).with_arguments(**arguments)
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

            # @deprecated replaced by {prefer_deployed_tasks}
            def use_deployments(*selection)
                prefer_deployed_tasks(*selection)
            end

            # @see InstanceRequirements#prefer_deployed_tasks
            def prefer_deployed_tasks(*selections)
                to_instance_requirements.prefer_deployed_tasks(*selections)
            end

            # @deprecated
            def use_conf(*spec, &block)
                with_conf(*spec, &block)
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.use_conf('special_conf'))
            #
            def with_conf(*spec, &block)
                InstanceRequirements.new([self]).with_conf(*spec, &block)
            end

            # Returns a view of this component as a producer of the given model
            #
            # This will fail if multiple services offer +service_model+. In this
            # case, one would have to first explicitely select the service and
            # only then call #as on the returned BoundDataService object
            def as(service_model)
                srv = find_data_service_from_type(service_model)
                unless srv
                    raise ArgumentError, "no service of #{self} provides #{service_model}"
                end

                srv.as(service_model)
            end

            # Defined to be compatible, in port mapping code, with the data services
            def port_mappings_for_task
                Hash.new { |_h, k| k }
            end

            # Defined to be compatible, in port mapping code, with the data services
            def port_mappings_for(model)
                unless model.kind_of?(Class)
                    return find_data_service_from_type(model).port_mappings_for_task
                end

                unless fullfills?(model)
                    raise ArgumentError,
                          "#{model.short_name} is not fullfilled by #{self}"
                end

                model.each_port.each_with_object({}) do |port, mappings|
                    mappings[port.name] = port.name
                end
            end

            # Finds a single service that provides +type+
            #
            # @see #find_all_data_services_from_type
            #
            # @param [Model<DataService>] type the data service type
            # @return [Models::BoundDataService,nil] the data service found, or
            #   nil if none can be found with the specified type
            # @raise AmbiguousServiceSelection if multiple services exist with
            #   that type
            def find_data_service_from_type(type)
                candidates = find_all_data_services_from_type(type)
                if candidates.size > 1
                    raise AmbiguousServiceSelection.new(self, type, candidates),
                          "multiple services match #{type.short_name} on #{short_name}"
                elsif candidates.size == 1
                    candidates.first
                end
            end

            # Finds a single service that provides +type+
            #
            # @see #find_data_service_from_type
            #
            # @param [Model<DataService>] type the data service type
            # @return [Array<Models::BoundDataService>] the list of data
            #   services that match the given type
            def find_all_data_services_from_type(type)
                result = []
                each_data_service do |_, m|
                    result << m.as(type) if m.fullfills?(type)
                end
                result
            end

            # Resolves the given port model into a component model where
            # {#component_model} is a proper component (e.g. not a
            # BoundDataService)
            #
            # It is not meant to be used directly. Use {Port#to_component_port}
            # instead
            #
            # @param [Models::Port] port a port in which {Port#component_model} == self
            # @return [Models::Port] a port in which {Port#component_model} is
            #   the "proper" component model that corresponds to self
            def self_port_to_component_port(port)
                port
            end

            # @api private
            #
            # Compute the port mapping from the interface of 'service' onto the
            # ports of 'self'
            #
            # The returned hash is
            #
            #   service_interface_port_name => task_model_port_name
            #
            # @param [{String=>String}] srv_to_self mapping from a port name in the
            #   provided service to the port name it should be mapped to on self
            # @raise InvalidPortMapping
            def compute_port_mappings(service_model, srv_to_self = {})
                normalized_srv_to_self =
                    normalize_port_mappings_argument(service_model, srv_to_self)

                output_srv_to_self = compute_output_port_mappings(
                    service_model, normalized_srv_to_self
                )
                input_srv_to_self = compute_input_port_mappings(
                    service_model, normalized_srv_to_self
                )

                # Note that the keys of 'mapped_input' and 'mapped_output' are this
                # component's port names. They are therefore guaranteed to have no
                # coll
                computed_srv_to_self = output_srv_to_self.merge(input_srv_to_self)
                check_collisions_in_computed_port_mappings(
                    computed_srv_to_self, srv_to_self
                )
                computed_srv_to_self
            end

            def normalize_port_mappings_argument(service_model, srv_to_self)
                srv_to_self.each_with_object({}) do |(srv_name, self_name), normalized|
                    srv_name  = srv_name.to_s  if srv_name.kind_of?(Symbol)
                    self_name = self_name.to_s if self_name.kind_of?(Symbol)

                    if !srv_name.respond_to?(:to_str)
                        raise ArgumentError,
                              "unexpected value given in port mapping: #{srv_name}, "\
                              "expected a string"
                    elsif !self_name.respond_to?(:to_str)
                        raise ArgumentError,
                              "unexpected value given in port mapping: #{self_name}, "\
                              "expected a string"
                    elsif !service_model.find_port(srv_name)
                        raise InvalidPortMapping,
                              "#{srv_name} is not a port of #{service_model}"
                    elsif !find_port(self_name)
                        raise InvalidPortMapping,
                              "#{self_name} is not a port of #{self}"
                    end

                    normalized[srv_name] = self_name
                end
            end

            def compute_output_port_mappings(service_model, given_srv_to_self)
                service_model.each_output_port.each_with_object({}) do |srv_port, mapped|
                    self_port_name = find_directional_port_mapping(
                        "output", srv_port, given_srv_to_self[srv_port.name]
                    )
                    unless self_port_name
                        raise InvalidPortMapping,
                              "cannot find an equivalent output port for "\
                              "#{srv_port.name}[#{srv_port.type_name}] on #{short_name}"
                    end

                    mapped[srv_port.name] = self_port_name
                end
            end

            def compute_input_port_mappings(service_model, given_srv_to_self)
                service_model.each_input_port.each_with_object({}) do |srv_port, mapped|
                    self_port_name = find_directional_port_mapping(
                        "input", srv_port, given_srv_to_self[srv_port.name]
                    )
                    unless self_port_name
                        raise InvalidPortMapping,
                              "cannot find an equivalent input port for "\
                              "#{srv_port.name}[#{srv_port.type_name}] on #{short_name}"
                    end

                    mapped[srv_port.name] = self_port_name
                end
            end

            def check_collisions_in_computed_port_mappings(
                computed_srv_to_self, given_srv_to_self
            )
                self_to_srv = computed_srv_to_self.group_by(&:last)
                self_to_srv.each do |self_port_name, srv_to_self_for_this|
                    next if srv_to_self_for_this.size == 1
                    # Let the user pass everything explicitly if he/she wishes to
                    next if srv_to_self_for_this.all? { |n, _| given_srv_to_self.key?(n) }

                    srv_port_names = srv_to_self_for_this.map(&:first)
                    explicit_mapping_s =
                        srv_port_names
                        .map { |o| "\"#{o}\" => \"#{self_port_name}\"" }
                        .join(", ")

                    raise InvalidPortMapping,
                          "automatic port mapping would map multiple service ports "\
                          "#{srv_port_names.sort.join(', ')} to the same component port "\
                          "#{self_port_name}. This is possible, but must be specified "\
                          "explicitly by passing this mapping: "\
                          "#{explicit_mapping_s} explicitly"
                end
            end

            # Finds the port of self that should be used for a service port
            # 'port'
            #
            # @param [String] direction it is 'input' or 'output' and
            #   caracterizes the direction of port
            # @param [Orocos::Spec::Port] port the port to be mapped
            # @param [String,nil] expected_name if not nil, it is an explicitly
            #   given port name for the component port
            #
            # @return [String,nil] the name of the port of self that should be
            #   used to map 'port'. It returns nil if there are no matching
            #   ports.
            # @raise InvalidPortMapping if expected_name is given but it is not
            #   a port of self, or not a port with the expected direction
            # @raise InvalidPortMapping if expected_name is given but the
            #   corresponding port has a wrong type
            # @raise InvalidPortMapping if expected_name was nil, no port exists
            #   on self with the same name than port and there are multiple ports
            #   with the same type than port
            def find_directional_port_mapping(direction, srv_port, given_self_port_name)
                if given_self_port_name
                    find_directional_port_mapping_by_name(
                        direction, srv_port, given_self_port_name
                    )
                else
                    find_directional_port_mapping_by_type(direction, srv_port)
                end
            end

            def find_directional_port_mapping_by_name(
                direction, srv_port, self_port_name
            )
                self_port = send("find_#{direction}_port", self_port_name)
                return self_port_name if self_port&.type == srv_port.type

                if self_port
                    raise InvalidPortMapping,
                          "invalid port mapping provided from #{srv_port} to "\
                          "#{self_port}: type mismatch"
                else
                    known_ports = send("each_#{direction}_port")
                                  .map { |p| "#{p.name}[#{p.type.name}]" }
                    raise InvalidPortMapping,
                          "invalid port mapping \"#{srv_port.name}\" => "\
                          "\"#{self_port_name}\": #{self_port_name} is not a "\
                          "#{direction} port in #{short_name}. "\
                          "Known #{direction} ports are #{known_ports.sort.join(', ')}"
                end
            end

            def find_directional_port_mapping_by_type(direction, srv_port)
                srv_port_type = srv_port.type
                candidates = send("each_#{direction}_port")
                             .find_all { |p| p.type == srv_port_type }
                return candidates.first&.name if candidates.size <= 1

                srv_port_name = srv_port.name
                return srv_port_name if candidates.any? { |p| p.name == srv_port_name }

                raise InvalidPortMapping,
                      "there are multiple candidates to map "\
                      "#{srv_port.name}[#{srv_port.type.name}]: "\
                      "#{candidates.map(&:name).sort.join(', ')}"
            end

            # Declares that this component model will dynamically provide the
            # ports necessary to provide a service model
            #
            # The main difference when compared to {#provides} is that service
            # ports that are not mapped to the task are automatically created
            # (provided a corresponding dynamic_input_port or
            # dynamic_output_port declaration exists on the oroGen model).
            #
            # @param [Syskit::DataService] service_model the service model
            # @param [Hash] port_mappings explicit port mappings needed to
            #   resolve the service's ports  to the task's ports
            # @param [String] as the name of the newly created {BoundDynamicDataService}
            # @param [BoundDataService,String,nil] slave_of if this service is slave of
            #   another, the master service
            # @return [BoundDynamicDataService]
            def provides_dynamic(
                service_model, port_mappings = {},
                as: nil, slave_of: nil, bound_service_class: BoundDataService
            )
                # Do not use #filter_options here, it will transform the
                # port names into symbols
                port_mappings = DynamicDataService.update_component_model_interface(
                    self, service_model, port_mappings
                )
                provides(service_model, port_mappings,
                         as: as,
                         slave_of: slave_of,
                         bound_service_class: bound_service_class)
            end

            # Called by the dynamic_service accessors to promote dynamic
            # services from our parent model to the corresponding dynamic
            # services on the child models
            def promote_dynamic_service(_name, dyn)
                dyn.attach(self)
            end

            # The set of dynamic services instantiated with #dynamic_service
            #
            # @key_name dynamic_service_name
            # @return [Hash<String,DynamicDataService>]
            inherited_attribute("dynamic_service", "dynamic_services", map: true) { {} }

            # Declares that this component model can dynamically extend its
            # interface by adding services of the given type
            #
            # This only models the functionality of dynamically creating new
            # services the actual related component setup needs to be done by
            # overloading the component's #configure method.
            #
            # @yield block that is evaluated to instantiate the service. It
            #   should call #provides with a data service that provides model (or
            #   model itself). The required data service name is accessible
            #   through the 'name' instance variable
            # @yieldreturn [Model<BoundDataService>] the new data service
            #
            # @option arguments [String] :as the dynamic service name. It is not
            #   the same than the actually creates services.
            #
            # @example
            #   class Example < Syskit::Composition
            #     dynamic_service CameraSrv, as: 'camera' do
            #       provides WeirdCameraSrv, 'image_samples' => '#{name}_samples'
            #     end
            #
            #     def configure
            #       super
            #       each_instantiated_dynamic_service('camera') do |bound_service|
            #         # setup the task to create the required service
            #       end
            #     end
            def dynamic_service( # rubocop:disable Metrics/ParameterLists
                model, as: nil,
                addition_requires_reconfiguration: true,
                remove_when_unused: true, **backward, &block
            )
                if !as
                    raise ArgumentError,
                          "no name given to the dynamic service, "\
                          "please provide one with the :as option"
                elsif !block_given?
                    raise ArgumentError,
                          "no block given to #dynamic_service, "\
                          "one must be provided and must call provides()"
                end

                if backward.key?(:dynamic)
                    Roby.warn_deprecated "the dynamic argument to #dynamic_service has "\
                                         "been renamed into "\
                                         "addition_requires_reconfiguration"
                    addition_requires_reconfiguration = !backward[:dynamic]
                end

                dynamic_services[as] = DynamicDataService.new(
                    self, as, model, block,
                    addition_requires_reconfiguration: addition_requires_reconfiguration,
                    remove_when_unused: remove_when_unused
                )
            end

            # Enumerates the services that have been created from a dynamic
            # service using #require_dynamic_service
            #
            # @yieldparam [DynamicDataService] srv
            def each_required_dynamic_service
                return enum_for(:each_required_dynamic_service) unless block_given?

                each_data_service do |_, srv|
                    yield(srv) if srv.dynamic?
                end
            end

            # Returns a model specialized from 'self' that has the required
            # dynamic service
            #
            # @see require_dynamic_service
            def with_dynamic_service(dynamic_service_name, options = {})
                model = ensure_model_is_specialized
                model.require_dynamic_service(dynamic_service_name, options)
                model
            end

            # Instanciate a dynamic service on this model
            #
            # @param [String] dynamic_service_name the name under which the
            #   dynamic service got registered when calling {#dynamic_service}
            # @param [String] as the name of the newly created service
            # @param dyn_options options passed to the dynamic service block
            #   through {DynamicDataService#instanciate}
            # @return [BoundDynamicDataService] the newly created service
            def require_dynamic_service(dynamic_service_name, as:, **dyn_options)
                service_name = as.to_str

                dyn = dynamic_service_by_name(dynamic_service_name)
                if (srv = find_data_service(service_name))
                    return srv if srv.fullfills?(dyn.service_model)

                    raise ArgumentError,
                          "there is already a service #{service_name}, but it is "\
                          "of type #{srv.model.short_name} while the dynamic "\
                          "service #{dynamic_service_name} expects "\
                          "#{dyn.service_model.short_name}"
                end
                dyn.instanciate(service_name, **dyn_options)
            end

            def dynamic_service_by_name(name)
                dyn = find_dynamic_service(name)
                return dyn if dyn

                dynamic_service_list =
                    each_dynamic_service.map { |n, _| n }.sort.join(", ")

                raise ArgumentError,
                      "#{short_name} has no dynamic service called "\
                      "#{name}, available dynamic services "\
                      "are: #{dynamic_service_list}"
            end

            # @api private
            #
            # Creation of a {DynamicDataService} instantiation context
            #
            # {DynamicDataService#instantiate} delegates to this method to
            # create the context in which the dynamic service setup block should
            # be evaluated. It allows subclasses to provide specific additional
            # APIs
            def create_dynamic_instantiation_context(name, dynamic_service, **options)
                DynamicDataService::InstantiationContext.new(
                    self, name, dynamic_service, **options
                )
            end

            def each_port
                []
            end

            def each_input_port
                []
            end

            def each_output_port
                []
            end

            def find_input_port(name); end

            def find_output_port(name); end

            def find_port(name); end

            PROVIDES_ARGUMENTS = { as: nil, slave_of: nil }.freeze

            # Declares that this component provides the given data service.
            # +model+ can either be the data service constant name (from
            # Syskit::DataServices), or its plain name.
            #
            # If the data service defines an interface, the component must
            # provide the required input and output ports. If an ambiguity
            # exists, explicit port mappings must be provided.
            #
            # @param [Hash] arguments option hash, as well as explicit port
            #   mappings. The values that are not reserved options (listed
            #   below) are used as port mappings, of the form:
            #      component_port_name => service_port_name
            #   I.e. they specify that service_port_name on the service should
            #   be mapped to component_port_name on the component
            # @option arguments [String] :slave_of the name of another data
            #   service, of which this service should be a slave.
            #
            # @raise ArgumentError if a data service with that name already
            #   exists
            # @raise SpecError if the new data service overrides a data service
            #   from the parent, but does not provide the service from this
            #   parent. See example below.
            #
            # @example Invalid service overriding. This is an error if Service2
            #   does not provide Service1
            #
            #   class TaskModel < Component
            #     provides Service, as: 'service'
            #   end
            #   class SubTaskModel < TaskModel
            #     provides Service2, as: 'service2'
            #   end
            #
            def provides(
                model, port_mappings = {}, as: nil,
                slave_of: nil, bound_service_class: BoundDataService
            )
                return super(model) if provides_for_task_service?(model, as: as)

                name, full_name, master = provides_resolve_name(
                    as: as, slave_of: slave_of
                )
                provides_validate_possible_overload(model, full_name)
                master = promote_service_if_needed(master) if master

                service = bound_service_class.new(name, self, master, model, {})
                provides_compute_port_mappings(service, port_mappings)

                register_bound_data_service(full_name, service)
                service
            end

            def provides_for_task_service?(model, as: nil)
                return if model.kind_of?(DataServiceModel)

                unless model.kind_of?(Roby::Models::TaskServiceModel)
                    raise ArgumentError,
                          "expected either a task service model or a data service model "\
                          "as argument, and got #{model}"
                end

                if as
                    raise ArgumentError,
                          "cannot give a name when providing a task service"
                end
                true
            end

            def provides_resolve_name(as:, slave_of: nil)
                unless as
                    raise ArgumentError,
                          "#provides requires a name to be provided through "\
                          "the 'as' option"
                end

                name = as.to_str
                full_name = name

                if slave_of.respond_to?(:to_str)
                    master_srv = find_data_service(slave_of)
                    unless master_srv
                        raise ArgumentError,
                              "master data service #{slave_of} is not "\
                              "registered on #{self}"
                    end

                    slave_of = master_srv
                end

                full_name = "#{slave_of.full_name}.#{name}" if slave_of
                [name, full_name, slave_of]
            end

            def provides_validate_possible_overload(model, full_name)
                # Get the source name and the source model
                if data_services[full_name]
                    raise ArgumentError,
                          "there is already a data service named '#{full_name}' "\
                          "defined on '#{short_name}'"
                end

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                return unless (parent_type = find_data_service(full_name)&.model)

                unless model <= parent_type
                    raise ArgumentError,
                          "#{self} has a data service named #{full_name} of type "\
                          "#{parent_type}, which is not a parent type of #{model}"
                end

                nil
            end

            def promote_service_if_needed(service)
                return service if service.component_model == self

                data_services[service.full_name] = service.attach(self)
            end

            # @api private
            #
            # Compute the port mappings for a newly provided service
            #
            # @raise InvalidPortMapping
            def provides_compute_port_mappings(service, given_srv_to_self = {})
                service_m = service.model
                new_port_mappings = compute_port_mappings(service_m, given_srv_to_self)
                service.port_mappings[service_m] = new_port_mappings
                Models.update_port_mappings(
                    service.port_mappings, new_port_mappings, service_m.port_mappings
                )
            rescue InvalidPortMapping => e
                raise InvalidProvides.new(self, service_m, e),
                      "#{short_name} does not provide the '#{service_m.name}' "\
                      "service's interface. #{e.message}", e.backtrace
            end

            def register_bound_data_service(full_name, service)
                include service.model
                data_services[full_name] = service

                Models.debug do
                    Models.debug "#{short_name} provides #{service}"
                    Models.debug "port mappings"
                    service.port_mappings.each do |m, mappings|
                        Models.debug "  #{m.short_name}: #{mappings}"
                    end
                    break
                end
            end

            # Declares that this task context model can be used as a driver for
            # the device +model+.
            #
            # It will create the corresponding device model if it does not
            # already exist, and return it. See the documentation of
            # Component.data_service for the description of +arguments+
            def driver_for(model, port_mappings = {}, **arguments)
                Roby.sanitize_keywords_to_hash(port_mappings, arguments)
                dserv = provides(model, port_mappings, **arguments)
                argument "#{dserv.name}_dev"
                dserv
            end

            # Test if the given port is a port of self
            #
            # @param [Port] port
            def self_port?(port)
                port.component_model == self
            end

            # If true, this model is used internally as specialization of
            # another component model (as e.g. to represent dynamic service
            # instantiation). Otherwise, it is an actual component model.
            #
            # @return [Model<TaskContext>]
            attr_predicate :private_specialization?, true

            # An ID that represents which specialized model this is
            def specialization_counter
                @specialization_counter ||= 0
                @specialization_counter += 1
            end

            # Called by {Component.specialize} to create the composition model
            # that will be used for a private specialization
            def create_private_specialization
                new_submodel
            end

            # Creates a private specialization of the current model
            def specialize(name = nil)
                klass = create_private_specialization
                klass.name = name ||
                             "#{self.name}{#{specialization_counter}}"
                klass.private_specialization = true
                klass.private_model
                klass.concrete_model = concrete_model
                klass
            end

            def implicit_fullfilled_model
                unless @implicit_fullfilled_model
                    has_abstract = false
                    @implicit_fullfilled_model =
                        super.find_all do |m|
                            has_abstract ||= (m == AbstractComponent)
                            !m.respond_to?(:private_specialization?) ||
                                !m.private_specialization?
                        end
                    @implicit_fullfilled_model << AbstractComponent \
                        unless has_abstract
                end
                @implicit_fullfilled_model
            end

            # Makes sure this is a private specialized model
            #
            # @return [Model<Component>] calls #specialize, and returns the new
            #   model, only if self is not already a private specialization.
            #   Otherwise, returns self.
            def ensure_model_is_specialized
                if private_specialization?
                    self
                else specialize
                end
            end

            # @see {concrete_model}
            attr_writer :concrete_model

            # If this model is specialized, returns the most derived model that
            # is non-specialized. Otherwise, returns self.
            def concrete_model
                @concrete_model || self
            end

            # Returns true if this model is a "true" concrete model or a
            # specialized one
            def concrete_model?
                concrete_model == self
            end

            # Returns a placeholder task that can be used to require that a
            # task from this component model is deployed and started at a
            # certain point in the plan.
            #
            # It is usually used implicitely with the plan and relation methods directly:
            #
            #   cmp = task.depends_on(Cmp::MyComposition)
            #
            # calls this method behind the scenes.
            def as_plan
                Syskit::InstanceRequirementsTask.subplan(self)
            end

            #
            #
            # @return [nil,Syskit::Component] task if it fullfills self,
            #   nil otherwise
            # @see #bind
            def try_bind(object)
                object if object.fullfills?(self)
            end

            # Return a representation of an instance that is compatible with
            # self
            #
            # @return [Roby::Task] task if it matches self
            # @raise [ArgumentError] if task does not fullfill self
            # @see #try_bind
            def bind(object)
                unless (component = try_bind(object))
                    raise ArgumentError, "cannot bind #{self} to #{object}"
                end

                component
            end

            # @deprecated use {#bind} instead
            def resolve(task)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                    "Models::Component#bind instead"
                bind(task)
            end

            # @deprecated use {#try_bind} instead
            def try_resolve(task)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                    "Models::Component#try_bind instead"
                try_bind(task)
            end

            # Delegated call from {Port#connected?}
            #
            # Always returns false as "plain" component ports cannot be
            # connected
            def connected?(_out_port, _in_port)
                false
            end

            # @api private
            #
            # Cache of models created by {Placeholder}
            attribute(:placeholder_models) { {} }

            # @api private
            #
            # Find an existing placeholder model based on self for the given
            # service models
            def find_placeholder_model(service_models, placeholder_type = Placeholder)
                return unless (by_type = placeholder_models[service_models])

                by_type[placeholder_type]
            end

            # @api private
            #
            # Register a new placeholder model for the given service models and
            # placeholder type
            def register_placeholder_model(
                placeholder_m, service_models, placeholder_type = Placeholder
            )
                by_type = (placeholder_models[service_models] ||= {})
                by_type[placeholder_type] = placeholder_m
            end

            # @api private
            #
            # Deregister a placeholder model
            def deregister_placeholder_model(placeholder_m)
                key = placeholder_m.proxied_data_service_models.to_set
                return unless (by_type = placeholder_models.delete(key))

                by_type.delete_if { |_, m| m == placeholder_m }
                placeholder_models[key] = by_type unless by_type.empty?
                true
            end

            # Clears all registered submodels
            def deregister_submodels(set)
                super

                if @placeholder_models
                    set.each do |m|
                        deregister_placeholder_model(m) if m.placeholder?
                    end
                end
                true
            end

            # @deprecated use {Models::Placeholder.create_for} instead
            def create_proxy_task_model(service_models, as: nil, extension: Placeholder)
                Roby.warn_deprecated "Component.create_proxy_task_model is deprecated, "\
                                     "use Syskit::Models::Placeholder.create_for instead"
                extension.create_for(service_models, component_model: self, as: as)
            end

            # @deprecated use {Models::Placeholder.for} instead
            def proxy_task_model(service_models, as: nil, extension: Placeholder)
                Roby.warn_deprecated "Component.proxy_task_model is deprecated, "\
                                     "use Syskit::Models::Placeholder.for instead"
                extension.for(service_models, component_model: self, as: as)
            end

            # Create a Roby task that can be used as a placeholder for self in
            # the plan
            #
            # The returned task is always marked as abstract
            def create_proxy_task
                task = new
                task.abstract = true
                task
            end

            # Wether this model represents a placeholder for data services
            #
            # @see Placeholder
            def placeholder?
                false
            end

            # Wether this model truly represents a component model
            #
            # @see Placeholder
            def component_model?
                true
            end

            # Adds a new port to this model based on a known dynamic port
            #
            # @param [String] name the new port's name
            # @param [Orocos::Spec::DynamicInputPort] port the port model, as
            #   returned for instance by
            #   Orocos::Spec::TaskContext#find_dynamic_input_ports
            # @return [Port] the new port's model
            def instanciate_dynamic_input_port(name, type, port)
                orogen_model = Models.create_orogen_task_context_model
                orogen_model.input_ports[name] = port.instanciate(name, type)
                Syskit::Models.merge_orogen_task_context_models(
                    self.orogen_model, [orogen_model]
                )
                find_input_port(name)
            end

            # Adds a new port to this model based on a known dynamic port
            #
            # @param [String] name the new port's name
            # @param [Orocos::Spec::DynamicOutputPort] port the port model, as
            #   returned for instance by
            #   Orocos::Spec::TaskContext#find_dynamic_output_ports
            # @return [Port] the new port's model
            def instanciate_dynamic_output_port(name, type, port)
                orogen_model = Models.create_orogen_task_context_model
                orogen_model.output_ports[name] = port.instanciate(name, type)
                Syskit::Models.merge_orogen_task_context_models(
                    self.orogen_model, [orogen_model]
                )
                find_output_port(name)
            end

            def fullfills?(object)
                return super unless object.respond_to?(:each_required_dynamic_service)

                self_real_model   = concrete_model
                object_real_model =
                    if object.respond_to?(:concrete_model)
                        object.concrete_model
                    else object
                    end

                return super if self_real_model == self

                return false if !self_real_model.fullfills?(object_real_model) ||
                                !object.respond_to?(:each_required_dynamic_service)

                # We've checked the public interface, Verify that we also have all
                # dynamic services instanciated in 'object'
                object.each_required_dynamic_service do |object_srv|
                    self_srv = find_data_service(object_srv.name)
                    return false if !self_srv ||
                                    !self_srv.dynamic? ||
                                    !self_srv.same_service?(object_srv)
                end
                true
            end

            def can_merge?(target_model)
                self_real_model = concrete_model
                target_real_model = target_model.concrete_model

                if self_real_model != self || target_real_model != target_model
                    return false unless self_real_model.can_merge?(target_real_model)
                elsif !super
                    return false
                end

                # Verify that we don't have collisions in the instantiated
                # dynamic services
                each_data_service.all? do |_, self_srv|
                    target_srv = target_model.find_data_service(self_srv.name)
                    next(true) unless target_srv

                    can_merge_service?(self_srv, target_srv)
                end
            end

            def can_merge_service?(self_srv, target_srv)
                if target_srv.model != self_srv.model
                    NetworkGeneration::MergeSolver.debug do
                        "rejecting #{self_srv}.merge(#{target_srv}): dynamic "\
                        "service #{self_srv.name} is of model "\
                        "#{self_srv.model.short_name} on self and of "\
                        "model #{target_srv.model.short_name} on the candidate task"
                    end
                    false
                elsif target_srv.dynamic? && self_srv.dynamic?
                    self_srv_options = self_srv.dynamic_service_options
                    target_srv_options = target_srv.dynamic_service_options
                    if self_srv_options == target_srv_options
                        true
                    else
                        NetworkGeneration::MergeSolver.debug do
                            "rejecting #{self_srv}.merge(#{target_srv}): dynamic "\
                            "service #{self_srv.name} has options "\
                            "#{target_srv.dynamic_service_options} on self and "\
                            "#{self_srv.dynamic_service_options} "\
                            "on the candidate task"
                        end
                        false
                    end
                elsif target_srv.dynamic? || self_srv.dynamic?
                    NetworkGeneration::MergeSolver.debug do
                        "rejecting #{self_srv}.merge(#{target_srv}): "\
                        "#{self_srv.name} is a dynamic service on self, "\
                        "but a static one on the candidate task"
                    end
                    false
                else
                    true
                end
            end

            def apply_missing_dynamic_services_from(from, specialize_if_needed = true)
                missing_services = from.each_data_service.find_all do |_, srv|
                    !find_data_service(srv.full_name)
                end

                if !missing_services.empty?
                    # We really really need to specialize self. The reason is
                    # that self.model, even though it has private
                    # specializations, might be a reusable model from the system
                    # designer's point of view. With the singleton class, we
                    # know that it is not
                    base_model = if specialize_if_needed then specialize
                                 else self
                                 end
                    missing_services.each do |_, srv|
                        dynamic_service_options =
                            { as: srv.name }.merge(srv.dynamic_service_options)
                        base_model.require_dynamic_service(
                            srv.dynamic_service.name, **dynamic_service_options
                        )
                    end
                    base_model
                else self
                end
            end

            # Returns the component model that is the merge model of self and
            # the given other model
            #
            # It will return self or other_model if they are "plain" models. In
            # case other_model is a placeholder task model, the corresponding
            # data service mappings will be computed and either self or another
            # placeholder task model will be returned
            def merge(other_model)
                if other_model.kind_of?(Syskit::Models::BoundDataService)
                    other_model.merge(self)
                elsif other_model.placeholder?
                    other_model.merge(self)
                elsif self <= other_model
                    self
                elsif other_model <= self
                    other_model
                elsif other_model.private_specialization? || private_specialization?
                    base_model = concrete_model.merge(other_model.concrete_model)
                    result = base_model.apply_missing_dynamic_services_from(self, true)
                    result.apply_missing_dynamic_services_from(
                        other_model, base_model == result
                    )

                else
                    raise IncompatibleComponentModels.new(self, other_model),
                          "models #{short_name} and #{other_model.short_name} "\
                          "are not compatible"
                end
            end

            def each_required_model
                return enum_for(:each_required_model) unless block_given?

                yield(concrete_model)
            end

            def selected_for(requirements)
                InstanceSelection.new(nil, to_instance_requirements,
                                      requirements.to_instance_requirements)
            end

            def merge_service_model(service_model, port_mappings)
                service_model.each_input_port do |p|
                    self_name = port_mappings[p.name] || p.name
                    self_p = find_input_port(self_name)
                    if !self_p
                        raise InvalidPortMapping,
                              "#{self} cannot dynamically create ports"
                    elsif p.type != self_p.type
                        raise InvalidPortMapping,
                              "#{self} already has a port named #{self_name} of type "\
                              "#{self_p.type}, cannot dynamically map #{p} onto it"
                    end
                end

                service_model.each_output_port do |p|
                    self_name = port_mappings[p.name] || p.name
                    self_p = find_output_port(self_name)
                    if !self_p
                        raise InvalidPortMapping,
                              "#{self} cannot dynamically create ports"
                    elsif p.type != self_p.type
                        raise InvalidPortMapping,
                              "#{self} already has a port named #{self_name} of "\
                              "type #{self_p.type}, cannot dynamically map #{p} onto it"
                    end
                end
            end

            def match
                Queries::ComponentMatcher.new.with_model(self)
            end

            # The data writers defined on this task, as a mapping from the writer's
            # registered name to the {DynamicPortBinding::BoundOutputReader} object.
            #
            # @key_name full_name
            # @return [Hash<String,DynamicPortBinding::BoundOutputReader>]
            inherited_attribute(:data_reader, :data_readers, map: true) do
                {}
            end

            # Define an output reader managed by this component
            #
            # Define a data reader that will be handled automatically by the Component
            # object. The reader will be made available through a `#{as}_reader`
            # accessor
            #
            # The port definition may either be a port of this component, a port
            # of a component child or a {Queries::PortMatcher} to dynamically bind
            # to ports in the plan based on e.g. data type or service type
            #
            # @example create a data reader for a composition child
            #    data_reader some_child.out_port, as: 'pose'
            #
            # @return [DynamicPortBinding::BoundOutputReader]
            def data_reader(port, as:)
                port = DynamicPortBinding.create(port)
                unless port.output?
                    raise ArgumentError,
                          "expected an output port, but #{port} seems to be an input"
                end

                data_readers[as] = port.to_bound_data_accessor(as, self)
            end

            # The data writers defined on this task, as a mapping from the writer's
            # registered name to the {DynamicPortBinding::BoundInputWriter} object.
            #
            # @key_name full_name
            # @return [Hash<String,DynamicPortBinding::BoundInputWriter>]
            inherited_attribute(:data_writer, :data_writers, map: true) do
                {}
            end

            # Define an input writer managed by this component
            #
            # Define a writer that will be handled automatically by the Component
            # object. The writer will be made available through a `#{as}_writer`
            # accessor
            #
            # The port definition may either be a port of this component, a port
            # of a component child or a {Queries::PortMatcher} to dynamically bind
            # to ports in the plan based on e.g. data type or service type
            #
            # @example create a data reader for a composition child
            #    data_reader some_child.cmd_in_port, as: 'cmd_in'
            #
            # @return [DynamicPortBinding::BoundInputWriter]
            def data_writer(port, as:)
                port = DynamicPortBinding.create(port)
                if port.output?
                    raise ArgumentError,
                          "expected an input port, but #{port} seems to be an output"
                end

                data_writers[as] = port.to_bound_data_accessor(as, self)
            end

            def has_through_method_missing?(name)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, name,
                    "_srv" => :find_data_service,
                    "_reader" => :find_data_reader,
                    "_writer" => :find_data_writer
                ) || super
            end

            def find_through_method_missing(name, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, name, args,
                    "_srv" => :find_data_service,
                    "_reader" => :find_data_reader,
                    "_writer" => :find_data_writer
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            ruby2_keywords def method_missing(name, *args, &block) # rubocop:disable Style/MissingRespondToMissing
                if name == :orogen_model
                    raise NoMethodError,
                          "tried to use a method to access an oroGen model, "\
                          "but none exists on #{self}"
                end

                super
            end
        end
    end
end
