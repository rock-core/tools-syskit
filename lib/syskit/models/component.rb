module Syskit
    module Models
        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module Component
            include Models::Base
            include MetaRuby::ModelAsClass
            include Syskit::DataService

            def to_component_model; self end

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
            inherited_attribute(:data_service, :data_services, :map => true) { Hash.new }

            def clear_model
                super
                data_services.clear
                dynamic_services.clear
                # Note: the proxy_task_models cache is cleared separately. The
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
            # @yield [Model<ComBus>] com_bus_model
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


            # Declares that this component model instantiates a dynamic service
            # of the given service model
            def provides_dynamic(service_model, arguments = Hash.new)
                # Do not use #filter_options here, it will transform the
                # port names into symbols
                arg_name = arguments.delete('as') || arguments.delete(:as)
                slave_of = arguments.delete('slave_of') || arguments.delete(:slave_of)
                port_mappings = DynamicDataService.update_component_model_interface(self, service_model, arguments)
                provides(service_model, port_mappings.merge(:as => arg_name, :slave_of => slave_of, :bound_service_class => BoundDynamicDataService))
            end

            # Called by the dynamic_service accessors to promote dynamic
            # services from our parent model to the corresponding dynamic
            # services on the child models
            def promote_dynamic_service(name, dyn)
                dyn.attach(self)
            end

            # The set of dynamic services instantiated with #dynamic_service
            #
            # @key_name dynamic_service_name
            # @return [Hash<String,DynamicDataService>]
            inherited_attribute('dynamic_service', 'dynamic_services', :map => true) { Hash.new }

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

                dynamic_services[arguments[:as]] = DynamicDataService.new(self, arguments[:as], model, block)
            end

            # Returns a model specialized from 'self' that has the required
            # dynamic service
            #
            # @see require_dynamic_service
            def with_dynamic_service(dynamic_service_name, options = Hash.new)
                model = ensure_model_is_specialized
                model.require_dynamic_service(dynamic_service_name, options)
                model
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

            def each_port; end
            def each_input_port; end
            def each_output_port; end
            def find_input_port(name); end
            def find_output_port(name); end
            def find_port(name); end

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
                    :slave_of => nil,
                    :bound_service_class => BoundDataService

                if !source_arguments[:as]
                    raise ArgumentError, "no service name given, please add the :as option"
                else name = source_arguments[:as]
                end
                full_name = name

                if master = source_arguments[:slave_of]
                    if master.respond_to?(:to_str)
                        master_srv = find_data_service(master)
                        if !master_srv
                            raise ArgumentError, "master data service #{master_source} is not registered on #{self}"
                        end
                        master = master_srv
                    end
                    full_name = "#{master.full_name}.#{name}"
                end

                # Get the source name and the source model
                if data_services[full_name]
                    raise ArgumentError, "there is already a data service named '#{full_name}' defined on '#{short_name}'"
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

                service = source_arguments[:bound_service_class].new(name, self, master, model, Hash.new)
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
                if m.to_s =~ /^(\w+)_srv$/
                    service_name = $1
                    if service_model = find_data_service(service_name)
                        if !args.empty?
                            raise ArgumentError, "#{m} expects zero arguments, got #{args.size}"
                        end
                        return service_model
                    else
                        raise NoMethodError.new("#{short_name} has no service called #{service_name}", m)
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
                klass.concrete_model = concrete_model
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

            # @see {concrete_model}
            attr_writer :concrete_model

            # If this model is specialized, returns the most derived model that
            # is non-specialized. Otherwise, returns self.
            def concrete_model
                if @concrete_model
                    return @concrete_model
                else return self
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

            def bind(object)
                if object.fullfills?(self) then object
                else raise ArgumentError, "#{object} does not provide #{self}, cannot bind"
                end
            end

            def can_merge?(target_model)
                self_real_model = if private_specialization? then superclass
                                  else self
                                  end
                target_real_model = if target_model.private_specialization? then target_model.superclass
                                    else target_model
                                    end

                if self_real_model != self || target_real_model != target_model
                    if !self_real_model.can_merge?(target_real_model)
                        return false
                    end
                elsif !super
                    return false
                end

                if private_specialization?
                    # Verify that we don't have collisions in the instantiated
                    # dynamic services
                    data_services.each_value do |self_srv|
                        if task_srv = target_model.find_data_service(self_srv.name)
                            if task_srv.model != self_srv.model
                                debug { "rejecting #{self}.merge(#{target_model}): dynamic service #{self_srv.name} is of model #{self_srv.model.short_name} on #{self} and of model #{task_srv.model.short_name} on #{target_model}" }
                                return false
                            end
                        end
                    end
                end
                return true
            end

            # Returns the component model that is the merge model of self and
            # the given other model
            #
            # It will return self or other_model if they are "plain" models. In
            # case other_model is a placeholder task model, the corresponding
            # data service mappings will be computed and either self or another
            # placeholder task model will be returned
            def merge(other_model)
                if other_model.respond_to?(:proxied_data_services)
                    return other_model.merge(self)
                elsif other_model.kind_of?(Syskit::Models::BoundDataService)
                    return other_model.merge(self)
                end

                if self <= other_model
                    return self
                elsif other_model <= self
                    return other_model
                else
                    raise IncompatibleComponentModels.new(self, other_model), "models #{short_name} and #{other_model.short_name} are not compatible"
                end
            end

            def each_required_model
                return enum_for(:each_required_model) if !block_given?
                yield(self)
            end

            def selected_for(requirements)
                InstanceSelection.new(nil, self.to_instance_requirements, requirements.to_instance_requirements)
            end
        end
    end

    # Model used to create a placeholder task from a concrete task model,
    # when a mix of data services and task context model cannot yet be
    # mapped to an actual task context model yet
    module PlaceholderTask
        module ClassExtension
            attr_accessor :proxied_data_services

            def proxied_task_context_model
                s = superclass
                if s != Syskit::Component
                    s
                end
            end

            def to_instance_requirements
                Syskit::InstanceRequirements.new([self])
            end

            def each_fullfilled_model(&block)
                fullfilled_model.each(&block)
            end

            def fullfilled_model
                result = Set.new
                if m = proxied_task_context_model
                    m.each_fullfilled_model do |m|
                        result << m
                    end
                end
                proxied_data_services.each do |srv|
                    srv.each_fullfilled_model do |m|
                        result << m
                    end
                end
                result
            end

            def each_required_model
                return enum_for(:each_required_model) if !block_given?
                if m = proxied_task_context_model
                    yield(m)
                end
                proxied_data_services.each do |m|
                    yield(m)
                end
            end

            def merge(other_model)
                if other_model.kind_of?(Models::BoundDataService)
                    return other_model.merge(self)
                end

                merged = Models.merge_model_lists(each_required_model, other_model.each_required_model)
                Syskit.proxy_task_model_for(merged)
            end

            def each_output_port
                return enum_for(:each_output_port) if !block_given?
                each_required_model do |m|
                    m.each_output_port do |p|
                        yield(p.attach(self))
                    end
                end
            end

            def each_input_port
                return enum_for(:each_input_port) if !block_given?
                each_required_model do |m|
                    m.each_input_port do |p|
                        yield(p.attach(self))
                    end
                end
            end

            def each_port
                return enum_for(:each_port) if !block_given?
                each_output_port { |p| yield(p) }
                each_input_port { |p| yield(p) }
            end

            def find_output_port(name)
                each_required_model do |m|
                    if p = m.find_output_port(name)
                        return p.attach(self)
                    end
                end
                nil
            end

            def find_input_port(name)
                each_required_model do |m|
                    if p = m.find_input_port(name)
                        return p.attach(self)
                    end
                end
                nil
            end

            def find_port(name)
                find_output_port(name) || find_input_port(name)
            end

            def to_s
                name
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
        service = nil
        models = models.map do |m|
            if m.respond_to?(:component_model)
                service = m
                m.component_model
            else m
            end
        end
        task_models, service_models = models.partition { |t| t <= Component }
        if task_models.size > 1
            raise ArgumentError, "cannot create a proxy for multiple component models at the same time"
        end

        # If all that is required is a proper task model, just return it
        task_model = task_models.first || Component
        task_model =
            if service_models.empty?
                task_model
            else
                task_model.proxy_task_model(service_models)
            end
        
        if service
            service.attach(task_model)
        else task_model
        end
    end
end

