module Syskit
    module Models
        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module Component
            include Models::Base
            include Syskit::DataService

            # Method that maps data services from this component's parent models
            # to this composition's own
            #
            # It is called as needed when calling {#each_data_service}
            def promote_data_service(full_name, service)
                service.attach(self)
            end

            # The data services defined on this task, as a mapping from the data
            # service full name to the BoundDataService object.
            #
            # @key_name full_name
            # @return [Hash<String,BoundDataService>]
            define_inherited_enumerable(:data_service, :data_services, :map => true) { Hash.new }

            def clear_model
                super
                data_services.clear
            end

            # Enumerate all the devices that are defined on this
            # component model
            #
            # @yields [Model<Device>]
            # @return [void]
            def each_master_driver_service(&block)
                return enum_for(:each_master_driver_service) if !block_given?
                each_root_data_service do |srv|
                    if srv.model < Syskit::Device
                        yield(srv)
                    end
                end
            end

            # Enumerate all the combus that are defined on this
            # component model
            #
            # @yields [Model<ComBus>]
            # @return [void]
            def each_com_bus_driver_service(&block)
                return enum_for(:each_com_bus_driver_service) if !block_given?
                each_root_data_service do |srv|
                    if srv.model < Syskit::ComBus
                        yield(srv)
                    end
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

                if matching_services.size > 1
                    main_matching_services = matching_services.
                        find_all { |service| service.master? }

                    if main_matching_services.size != 1
                        raise AmbiguousServiceSelection.new(self, target_model, main_matching_services), "there is more than one service of type #{target_model.name} in #{self.name}#{" matching name hint #{pattern}" if pattern}"
                    end
                    selected = main_matching_services.first
                else
                    selected = matching_services.first
                end

                selected
            end

            # Enumerates all services that are slave (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_slave_data_service(master_service)
                return enum_for(:each_slave_data_service, master_service) if !block_given?
                each_data_service(nil) do |name, service|
                    if service.master && (service.master.full_name == master_service.full_name)
                        yield(service)
                    end
                end
            end

            # Enumerates all services that are root (i.e. not slave of other
            # services)
            #
            # @yield [Models::BoundDataService]
            def each_root_data_service(&block)
                return enum_for(:each_root_data_service) if !block_given?
                each_data_service(nil) do |name, service|
                    if service.master?
                        yield(service)
                    end
                end
            end

            # Generic instanciation of a component. 
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the plan and returns it.
            def instanciate(plan, context = DependencyInjectionContext.new, arguments = Hash.new)
                task_arguments, instanciate_arguments = Kernel.
                    filter_options arguments, :task_arguments => Hash.new
                plan.add(task = new(task_arguments[:task_arguments]))
                task
            end

            # The model next in the ancestry chain, or nil if +self+ is root
            def supermodel
                if superclass.respond_to?(:register_submodel)
                    return superclass
                end
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.with_arguments('special_behaviour' => true))
            #
            def with_arguments(*spec, &block)
                InstanceRequirements.new([self]).with_arguments(*spec, &block)
            end

            def use_deployments(*selection)
                to_instance_requirements.use_deployments(*selection)
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
                return srv.as(service_model)
            end

	    # Defined to be compatible, in port mapping code, with the data services
	    def port_mappings_for_task
	    	Hash.new { |h,k| k }
	    end

	    # Defined to be compatible, in port mapping code, with the data services
            def port_mappings_for(model)
                if model.kind_of?(Class) 
                    if self <= model
                        mappings = Hash.new
                        model.each_port do |port|
                            mappings[port.name] = port.name
                        end
                        mappings
                    else
                        raise ArgumentError, "#{model.short_name} is not fullfilled by #{self}"
                    end
                else
                    find_data_service_from_type(model).port_mappings_for_task
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
                    return candidates.first
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
                    result << m if m.fullfills?(type)
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
            # @param [Models::Port] a port in which {Port#component_model} == self
            # @return [Models::Port] a port in which {Port#component_model} is
            #   the "proper" component model that corresponds to self
            def self_port_to_component_port(port)
                return port
            end

            # Compute the port mapping from the interface of 'service' onto the
            # ports of 'self'
            #
            # The returned hash is
            #
            #   service_interface_port_name => task_model_port_name
            #
            def compute_port_mappings(service_model, explicit_mappings = Hash.new)
                normalized_mappings = Hash.new
                explicit_mappings.each do |from, to|
                    from = from.to_s if from.kind_of?(Symbol)
                    to   = to.to_s   if to.kind_of?(Symbol)
                    if from.respond_to?(:to_str) && to.respond_to?(:to_str)
                        normalized_mappings[from] = to 
                    end
                end

                result = Hash.new
                service_model.each_output_port do |port|
                    if mapped_name = find_directional_port_mapping('output', port, normalized_mappings[port.name])
                        result[port.name] = mapped_name
                    else
                        raise InvalidPortMapping, "cannot find an equivalent output port for #{port.name}[#{port.type_name}] on #{short_name}"
                    end
                end
                service_model.each_input_port do |port|
                    if mapped_name = find_directional_port_mapping('input', port, normalized_mappings[port.name])
                        result[port.name] = mapped_name
                    else
                        raise InvalidPortMapping, "cannot find an equivalent input port for #{port.name}[#{port.type_name}] on #{short_name}"
                    end
                end
                result
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
            def find_directional_port_mapping(direction, port, expected_name)
                port_name = expected_name || port.name
                component_port = send("find_#{direction}_port", port_name)

                if component_port && component_port.type == port.type
                    return port_name
                elsif expected_name
                    if !component_port
                        raise InvalidPortMapping, "the provided port mapping from #{port.name} to #{port_name} is invalid: #{port_name} is not a #{direction} port in #{short_name}"
                    else
                        raise InvalidPortMapping, "the provided port mapping from #{port.name} to #{port_name} is invalid: #{port_name} is of type #{component_port.type_name} in #{short_name} and I was expecting #{port.type}"
                    end
                end

                candidates = send("each_#{direction}_port").
                    find_all { |p| p.type == port.type }
                if candidates.empty?
                    return
                elsif candidates.size == 1
                    return candidates.first.name
                else
                    raise InvalidPortMapping, "there are multiple candidates to map #{port.name}[#{port.type_name}]: #{candidates.map(&:name).sort.join(", ")}"
                end
            end


            # Intermediate object used to evaluate the blocks given to
            # Component#dynamic_service
            class DynamicServiceInstantiationContext
                # The component model in which this service is being
                # instantiated
                attr_reader :component_model
                # The name of the service that is being instantiated
                attr_reader :name
                # The dynamic service description
                attr_reader :dynamic_service
                # The instantiated service
                attr_reader :service
                # A set of options that are accessible from the instanciation
                # block. This allows to create protocols for dynamic service
                # creation, and is specific to the client component model
                # @return [Hash]
                attr_reader :options

                def initialize(component_model, name, dynamic_service, options = Hash.new)
                    @component_model, @name, @dynamic_service, @options =
                        component_model, name, dynamic_service, options
                end

                # Proxy for component_model#provides which does some sanity
                # checks
                def provides(service_model, arguments = Hash.new)
                    if service
                        raise ArgumentError, "this dynamic service instantiation block already created one new service"
                    end

                    if !service_model.fullfills?(dynamic_service.service_model)
                        raise ArgumentError, "#{service_model.short_name} does not fullfill the model for the dynamic service #{dynamic_service.name}, #{dynamic_service.service_model.short_name}"
                    end

                    arg_name = arguments.delete('as') || arguments.delete(:as)
                    if arg_name && arg_name != name
                        raise ArgumentError, "a :as argument of \"#{arg_name}\" was given but it is required to be #{name}. Note that it can be omitted in a dynamic service block"
                    end
                    @service = component_model.provides_dynamic(service_model, arguments.merge(:as => name))
                end
            end

            # Representation of a dynamic service registered with
            # Component#dynamic_service
            class DynamicService
                # The component model we are bound to
                attr_reader :component_model
                # The dynamic service name
                attr_reader :name
                # The service model
                attr_reader :service_model
                # The service definition block
                attr_reader :block

                def initialize(component_model, name, service_model, block)
                    @component_model, @name, @service_model, @block = component_model, name, service_model, block
                end

                def attach(component_model)
                    result = dup
                    result.instance_variable_set(:@component_model, component_model)
                    result
                end

                def instanciate(name, options = Hash.new)
                    instantiator = DynamicServiceInstantiationContext.new(component_model, name, self, options)
                    instantiator.instance_eval(&block)
                    if !instantiator.service
                        raise InvalidDynamicServiceBlock.new(self), "the block #{block} used to instantiate the dynamic service #{name} on #{component_model.short_name} with options #{options} did not provide any service"
                    end
                    instantiator.service
                end

                # Updates the component_model's oroGen interface description to
                # include the ports needed for the given dynamic service model
                #
                # @return [Hash{String=>String}] the updated port mappings
                def self.update_component_model_interface(component_model, service_model, user_port_mappings)
                    port_mappings = Hash.new
                    service_model.each_output_port do |service_port|
                        port_mappings[service_port.name] = directional_port_mapping(component_model, 'output', service_port, user_port_mappings[service_port.name])
                    end
                    service_model.each_input_port do |service_port|
                        port_mappings[service_port.name] = directional_port_mapping(component_model, 'input', service_port, user_port_mappings[service_port.name])
                    end

                    # Unlike #data_service, we need to add the service's interface
                    # to our own
                    Syskit::Models.merge_orogen_task_context_models(component_model.orogen_model, [service_model.orogen_model], port_mappings)
                    port_mappings
                end

                # Validates the setup for a single data service port, and
                # computes the port mapping for it. It validates the port
                # creation rule that a mapping must be given for a port to be
                # created.
                def self.directional_port_mapping(component_model, direction, port, expected_name)
                    # Filter out the ports that already exist on the component
                    if expected_name
                        if component_model.send("find_#{direction}_port", expected_name)
                            return expected_name
                        end
                    else
                        expected_name = component_model.find_directional_port_mapping(direction, port, nil)
                        if !expected_name
                            raise ArgumentError, "no explicit mapping has been given for the service port #{port.name} and no port on #{component_model.short_name} matches. You must give an explicit mapping of the form 'service_port_name' => 'task_port_name' if you expect the port to be dynamically created."
                        end
                        return expected_name
                    end

                    # Now verify that the rest can be instanciated
                    if !component_model.send("has_dynamic_#{direction}_port?", expected_name, port.type)
                        raise ArgumentError, "there are no dynamic #{direction} ports declared in #{component_model.short_name} that match #{expected_name}:#{port.type_name}"
                    end
                    return expected_name
                end
            end

            # Declares that this component model instantiates a dynamic service
            # of the given service model
            def provides_dynamic(service_model, arguments = Hash.new)
                # Do not use #filter_options here, it will transform the
                # port names into symbols
                arg_name = arguments.delete('as') || arguments.delete(:as)
                port_mappings = DynamicService.update_component_model_interface(self, service_model, arguments)
                provides(service_model, port_mappings.merge(:as => arg_name))
            end

            # Called by the dynamic_service accessors to promote dynamic
            # services from our parent model to the corresponding dynamic
            # services on the child models
            def promote_dynamic_service(name, dyn)
                dyn.attach(self)
            end

            # The set of dynamic services instantiated with #dynamic_service
            #
            # @map_key dynamic_service_name
            # @return [Hash<String,DynamicService>]
            define_inherited_enumerable('dynamic_service', 'dynamic_services', :map => true) { Hash.new }

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
            #     dynamic_service CameraSrv, :as => 'camera' do
            #       provides WeirdCameraSrv, 'image_samples' => '#{name}_samples'
            #     end
            #
            #     def configure
            #       super
            #       each_instantiated_dynamic_service('camera') do |bound_service|
            #         # setup the task to create the required service
            #       end
            #     end
            def dynamic_service(model, arguments = Hash.new, &block)
                arguments = Kernel.validate_options arguments, :as => nil
                if !arguments[:as]
                    raise ArgumentError, "no name given to the dynamic service, please provide one with the :as option"
                elsif !block_given?
                    raise ArgumentError, "no block given to #dynamic_service"
                end

                dynamic_services[arguments[:as]] = DynamicService.new(self, arguments[:as], model, block)
            end

            # Instanciate a dynamic service on this model
            def require_dynamic_service(dynamic_service_name, options = Hash.new)
                options, dyn_options = Kernel.filter_options options,
                    :as => nil
                if !options[:as]
                    raise ArgumentError, "no name given, please provide the :as option"
                end
                service_name = options[:as]

                dyn = find_dynamic_service(dynamic_service_name)
                if !dyn
                    raise ArgumentError, "#{short_name} has no dynamic service called #{dynamic_service_name}, available dynamic services are: #{each_dynamic_service.map { |name, _| name }.sort.join(", ")}"
                end

                if srv = find_data_service(service_name)
                    if srv.fullfills?(dyn.service_model)
                        return srv
                    else raise ArgumentError, "there is already a service #{service_name}, but it is of type #{srv.model.short_name} while the dynamic service #{dynamic_service_name} expects #{dyn.service_model.short_name}"
                    end
                end
                dyn.instanciate(service_name, dyn_options)
            end

            PROVIDES_ARGUMENTS = { :as => nil, :slave_of => nil }

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
            # @option arguments [String] :as the name of the service. If it is
            #   not given, the basename of the model name converted to snake case
            #   is used, e.g. ImageProvider becomes image_provider.
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
            #     provides Service, :as => 'service'
            #   end
            #   class SubTaskModel < TaskModel
            #     provides Service2, :as => 'service2'
            #   end
            #
            def provides(model, arguments = Hash.new)
                source_arguments, arguments = Kernel.filter_options arguments,
                    :as => nil,
                    :slave_of => nil

                if !source_arguments[:as]
                    raise ArgumentError, "no service name given, please add the :as option"
                else name = source_arguments[:as]
                end
                full_name = name

                if master_source = source_arguments[:slave_of]
                    master = find_data_service(master_source)
                    if !master
                        raise ArgumentError, "master data service #{master_source} is not registered on #{self}"
                    end
                    full_name = "#{master.full_name}.#{name}"
                end

                # Get the source name and the source model
                if data_services[full_name]
                    raise ArgumentError, "there is already a data service named '#{name}' defined on '#{short_name}'"
                end

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                if has_data_service?(full_name)
                    parent_type = find_data_service(full_name).model
                    if !(model <= parent_type)
                        raise ArgumentError, "#{self} has a data service named #{full_name} of type #{parent_type}, which is not a parent type of #{model}"
                    end
                end

                if master && (master.component_model != self)
                    data_services[master.full_name] = master.attach(self)
                end

                begin
                    new_port_mappings = compute_port_mappings(model, arguments)
                rescue InvalidPortMapping => e
                    raise InvalidProvides.new(self, model, e), "#{short_name} does not provide the '#{model.name}' service's interface. #{e.message}", e.backtrace
                end

                service = BoundDataService.new(name, self, master, model, Hash.new)
                service.port_mappings[model] = new_port_mappings

                # Now, adapt the port mappings from +model+ itself and map
                # them into +service.port_mappings+
                Models.update_port_mappings(service.port_mappings, new_port_mappings, model.port_mappings)

                # Remove from +arguments+ the items that were port mappings
                new_port_mappings.each do |from, to|
                    if arguments[from].to_s == to # this was a port mapping !
                        arguments.delete(from)
                    elsif arguments[from.to_sym].to_s == to
                        arguments.delete(from.to_sym)
                    end
                end

                include model

                data_services[full_name] = service

                Models.debug do
                    Models.debug "#{short_name} provides #{model.short_name}"
                    Models.debug "port mappings"
                    service.port_mappings.each do |m, mappings|
                        Models.debug "  #{m.short_name}: #{mappings}"
                    end
                    break
                end

                arguments.each do |key, value|
                    send("#{key}=", value)
                end
                return service
            end

            # Declares that this task context model can be used as a driver for
            # the device +model+.
            #
            # It will create the corresponding device model if it does not
            # already exist, and return it. See the documentation of
            # Component.data_service for the description of +arguments+
            def driver_for(model, arguments = Hash.new, &block)
                if model.respond_to?(:to_str)
                    has_proper_name =
                        if self.name
                            begin constant(self.name)
                            rescue NameError
                            end
                        end

                    if has_proper_name
                        parent_module_name = name.gsub(/::[^:]+$/, '')
                        parent_module =
                            if parent_module_name == model then Object
                            else constant(parent_module_name)
                            end
                    end

                    if parent_module
                        model = parent_module.device_type(model)
                    else
                        model = Device.new_submodel(:name => model)
                    end
                end

                dserv = provides(model, arguments)
                argument "#{dserv.name}_dev"
                dserv
            end


            def method_missing(m, *args)
                if m == :orogen_model
                    raise NoMethodError, "tried to use a method to access an oroGen model, but none exists on #{self}"
                end
                if args.empty? && !block_given?
                    if m.to_s =~ /^(\w+)_srv$/
                        service_name = $1
                        if service_model = find_data_service(service_name)
                            return service_model
                        else
                            raise NoMethodError, "#{short_name} has no service called #{service_name}"
                        end
                    end
                end
                super
            end

            # If true, this model is used internally as specialization of
            # another component model (as e.g. to represent dynamic service
            # instantiation). Otherwise, it is an actual component model.
            #
            # @return [Model<TaskContext>]
            attr_predicate :private_specialization?, true

            # Creates a private specialization of the current model
            def specialize(name = nil)
                klass = new_submodel
                if name
                    klass.name = name
                end
                klass.private_specialization = true
                klass.private_model
                klass
            end

            # Makes sure this is a private specialized model
            #
            # @return [Model<Component>] calls #specialize, and returns the new
            #   model, only if self is not already a private specialization.
            #   Otherwise, returns self.
            def ensure_model_is_specialized
                if private_specialization?
                    return self
                else return specialize
                end
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

            # Try resolving the given task using this model
            #
            # @return [nil,Roby::Task] task if it matches +self+, nil otherwise
            def try_resolve(task)
                task if task.kind_of?(self)
            end

            # Resolves the given task using this model
            #
            # @return [Roby::Task] task if it matches self
            # @raise [ArgumentError] if task does not fullfill self
            def resolve(task)
                if task = try_resolve(task)
                    task
                else
                    raise ArgumentError, "cannot resolve #{self} into #{component}"
                end
            end

            # [Hash{Array<DataService> => Models::Task}] a cache of models
            # creates in #proxy_task_model
            attribute(:proxy_task_models) { Hash.new }

            # Create a task model that can be used as a placeholder in a Roby
            # plan for this task model and the following service models.
            #
            # @see Syskit.proxy_task_model_for
            def proxy_task_model(service_models)
                service_models = service_models.to_set
                if task_model = proxy_task_models[service_models]
                    return task_model
                end

                name = "Syskit::PlaceholderTask<#{self.short_name},#{service_models.map(&:short_name).sort.join(",")}>"
                model = specialize(name)
                model.abstract
                model.include PlaceholderTask
                model.proxied_data_services = service_models.dup
		model.fullfilled_model = [self] + model.proxied_data_services.to_a

                Syskit::Models.merge_orogen_task_context_models(model.orogen_model, service_models.map(&:orogen_model))
                service_models.each_with_index do |m, i|
                    model.provides m, :as => "m#{i}"
                end
                proxy_task_models[service_models] = model
                model
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

            # Adds a new port to this model based on a known dynamic port
            # 
            # @param [String] name the new port's name
            # @param [Orocos::Spec::DynamicInputPort] port the port model, as
            #   returned for instance by Orocos::Spec::TaskContext#find_dynamic_input_ports
            # @return [Port] the new port's model
            def instanciate_dynamic_input_port(name, type, port)
                orogen_model = Orocos::Spec::TaskContext.new
                orogen_model.input_ports[name] = port.instanciate(name, type)
                Syskit::Models.merge_orogen_task_context_models(self.orogen_model, [orogen_model])
                find_input_port(name)
            end

            # Adds a new port to this model based on a known dynamic port
            # 
            # @param [String] name the new port's name
            # @param [Orocos::Spec::DynamicOutputPort] port the port model, as
            #   returned for instance by Orocos::Spec::TaskContext#find_dynamic_output_ports
            # @return [Port] the new port's model
            def instanciate_dynamic_output_port(name, type, port)
                orogen_model = Orocos::Spec::TaskContext.new
                orogen_model.output_ports[name] = port.instanciate(name, type)
                Syskit::Models.merge_orogen_task_context_models(self.orogen_model, [orogen_model])
                find_output_port(name)
            end
        end
    end

    # Model used to create a placeholder task from a concrete task model,
    # when a mix of data services and task context model cannot yet be
    # mapped to an actual task context model yet
    module PlaceholderTask
        module ClassExtension
            attr_accessor :proxied_data_services

            def to_instance_requirements
                Syskit::InstanceRequirements.new(proxied_data_services)
            end
        end

        def proxied_data_services
            self.model.proxied_data_services
        end
    end

    # This method creates a task model that can be used to represent the
    # models listed in +models+ in a plan. The returned task model is
    # obviously abstract
    def self.proxy_task_model_for(models)
        task_models, service_models = models.partition { |t| t <= Component }
        if task_models.size > 1
            raise ArgumentError, "cannot create a proxy for multiple component models at the same time"
        end
        task_model = task_models.first || TaskContext

        # If all that is required is a proper task model, just return it
        if service_models.empty?
            return task_model
        end

        task_model.proxy_task_model(service_models)
    end
end

