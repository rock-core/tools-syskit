module Syskit
        Roby::EventStructure.relation 'SyskitConfigurationPrecedence'

        # Base class for models that represent components (TaskContext,
        # Composition)
        #
        # The model-level methods (a.k.a. singleton methods) are defined on
        # Models::Component). See the documentation of Model for an explanation of
        # this.
        #
        # Components may be data service providers. Two types of data sources
        # exist:
        # * main services are root data services that can be provided
        #   independently
        # * slave sources are data services that depend on another service. For
        #   instance, an ImageProvider source of a StereoCamera task could be
        #   slave of the main PointCloudProvider source.
        #
        # Data services are referred to by name. In the case of a main service,
        # its name is the name used during the declaration. In the case of slave
        # services, it is main_data_service_name.slave_name. I.e. the name of
        # the slave service depends on the selected 
        class Component < ::Roby::Task
            extend Models::Component
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Syskit::PortAccess

            abstract
            terminates

            # The name of the process server that should run this component
            #
            # On regular task contexts, it is the host on which the task is
            # required to run. On compositions, it affects the composition's
            # children
            attr_accessor :required_host

            # The InstanceRequirements object for which this component has been
            # instanciated.
            attr_reader :requirements

            # The PortDynamics object that holds the dynamics information
            # computed for this task (not its ports)
            # @return [NetworkGeneration::PortDynamics]
            attr_accessor :dynamics

            def initialize(options = Hash.new)
                super
                @requirements = InstanceRequirements.new
            end

            def initialize_copy(source)
                super
                @requirements = @requirements.dup
                if source.specialized_model?
                    specialize
                end
                duplicate_missing_services_from(source)
            end

            def create_fresh_copy
                new_task = super
                new_task.robot = robot
                new_task
            end

            # Wether this component instance is a placeholder for data services
            #
            # @see Models::PlaceholderTask
            def placeholder_task?
                false
            end

            # Returns a set of hints that should be used to disambiguate the
            # deployment of this task.
            #
            # It looks for #deployment_hints in the requirements. If there are
            # none, it then looks in the parents.
            def deployment_hints
                hints = requirements.deployment_hints
                return hints if !hints.empty?

                result = Set.new
                each_parent_task do |p|
                    result |= p.deployment_hints
                end
                result
            end

            # Returns the set of models this task fullfills
            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            # Yields the data services that are defined on this task
            def each_data_service
                return enum_for(:each_data_service) if !block_given?
                model.each_data_service do |name, srv|
                    yield(srv.bind(self))
                end
                self
            end

            # Finds a data service by its name
            #
            # @param [String] service_name the data service name
            # @return [BoundDataService,nil] the found data service, or nil if
            #   there are no services with that name in self
            def find_data_service(service_name)
                if service_model = model.find_data_service(service_name)
                    return service_model.bind(self)
                end
            end

            # Finds a data service by its data service model
            #
            # @param [Model<DataService>] service_type the data service model we want to find
            #   in self
            # @return [BoundDataService,nil] the found data service, or nil if there
            #   are no services of that type in self
            # @raise (see Models::DataService#find_data_service_from_type)
	    def find_data_service_from_type(service_type)
                if service_model = model.find_data_service_from_type(service_type)
                    return service_model.bind(self)
                end
	    end

            # Declare that this component should not be configured until +event+
            # has been emitted. This is used to sequence configurations with
            # other system events, but should not be required in most cases
            def should_configure_after(object)
                # To make the scheduler happy
                should_start_after object
                object.add_syskit_configuration_precedence(start_event)
            end

            # Returns true if the underlying Orocos task is in a state that
            # allows it to be configured
            def ready_for_setup? # :nodoc:
                return false if !fully_instanciated?

                start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).all? do |event|
                    event.emitted?
                end
            end

            # Returns true if the underlying Orocos task has been properly
            # configured
            attr_predicate :setup?, true

            # Call to configure the component. User-provided configuration calls
            # should be defined in a #configure method
            #
            # Note that for error-handling reasons, the setup? flag is not set
            # by this method. Caller must call is_setup! after a successful call
            # to #setup
            #
            # @return [Promise] #setup must schedule the work to be done in a
            #   promise, to allow subclasses to schedule work 
            def setup(promise)
                promise.on_success do
                    freeze_delayed_arguments
                    if self.model.needs_stub?(self)
                        self.model.prepare_stub(self)
                    end
                    configure
                end
            end

            def is_setup!
                @setting_up = nil
                self.setup = true
            end

            def setting_up?
                @setting_up && !@setting_up.complete?
            end

            def setting_up!(promise)
                promise.on_error do |e|
                    if start_event.plan
                        start_event.emit_failed(e)
                    else
                        Roby.execution_engine.add_framework_error(e, "#{self}.setting_up!")
                    end
                end
                promise.execute
                @setting_up = promise
            end

            # User-provided part of the component configuration
            def configure
                super if defined? super
            end

            # Test if the given task could be merged in self
            #
            # This method should only consider intrinsic criteria for the
            # merge, as e.g. compatibility of models or the value abstract? It
            # should never look into the task's neighborhood
            def can_merge?(task)
                if !super
                    NetworkGeneration::MergeSolver.info "rejected: Component#can_merge? super returned false"
                    return
                end

                # Cannot merge if we are not reusable
                if !reusable?
                    NetworkGeneration::MergeSolver.info "rejected: receiver is not reusable"
                    return
                end
                # We can not replace a non-abstract task with an
                # abstract one
                if !task.abstract? && abstract?
                    NetworkGeneration::MergeSolver.info "rejected: cannot merge a non-abstract task into an abstract one"
                    return
                end
                return true
            end

            # Tests whether a task can be used as-is to deploy this
            #
            # It is mostly the same as {#can_merge?}, while taking into account
            # e.g. that some operations done during merging will require the
            # component to do a reconfiguration cycle
            #
            # @param [Component] task
            # @return [Boolean]
            def can_be_deployed_by?(task)
                task.can_merge?(self)
            end

            # Updates self so that it is a valid replacement for merged_task
            #
            # This method assumes that #can_merge?(task) has already been called
            # and returned true
            def merge(merged_task)
                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each do |key, value|
                    if value.respond_to?(:evaluate_delayed_argument)
                        arguments[key] = value if !arguments.assigned?(key)
                    else
                        arguments[key] = value if !arguments.set?(key)
                    end
                end

                # Merge the fullfilled model if set explicitely
                explicit_merged_fullfilled_model = merged_task.explicit_fullfilled_model
                explicit_this_fullfilled_model   = explicit_fullfilled_model
                if explicit_this_fullfilled_model && explicit_merged_fullfilled_model
                    self.fullfilled_model = Roby::TaskStructure::Dependency.merge_fullfilled_model(
                        explicit_merged_fullfilled_model,
                        [explicit_this_fullfilled_model[0]] + explicit_this_fullfilled_model[1],
                        explicit_this_fullfilled_model[2])

                elsif explicit_merged_fullfilled_model
                    self.fullfilled_model = explicit_merged_fullfilled_model.dup
                end

                # Merge the InstanceRequirements objects
                requirements.merge(merged_task.requirements)

                # If merged_task has instantiated dynamic services, instantiate
                # them on self
                if merged_task.model.private_specialization?
                    duplicate_missing_services_from(merged_task)
                end

                nil
            end

            def duplicate_missing_services_from(task)
                missing_services = task.model.each_data_service.find_all do |_, srv|
                    !model.find_data_service(srv.full_name)
                end

                missing_services.each do |_, srv|
                    if !srv.respond_to?(:dynamic_service)
                        raise InternalError, "attempting to duplicate static service #{srv.name} from #{task} to #{self}"
                    end
                    dynamic_service_options = Hash[as: srv.name].
                        merge(srv.dynamic_service_options)
                    require_dynamic_service srv.dynamic_service.name, **dynamic_service_options
                end
            end

            # The set of data readers created with #data_reader. Used to disconnect
            # them when the task stops
            attribute(:data_readers) { Array.new }

            # The set of data writers created with #data_writer. Used to disconnect
            # them when the task stops
            attribute(:data_writers) { Array.new }

            # Common implementation of port search for #data_reader and
            # #data_writer
            def data_accessor(*args) # :nodoc:
                policy = Hash.new
                if args.last.respond_to?(:to_hash)
                    policy = args.pop
                end

                port_name = args.pop
                if !args.empty?
                    role_path = args
                    parent = resolve_role_path(role_path[0..-2])
                    task   = parent.child_from_role(role_path.last)
                    if parent.respond_to?(:map_child_port)
                        port_name = parent.map_child_port(role_path.last, port_name)
                    end
                else
                    task = self
                end

                return task, port_name, policy
            end

            # call-seq:
            #   data_writer 'port_name'[, policy]
            #   data_writer 'role_name', 'port_name'[, policy]
            #
            # Returns a data writer that allows to read the specified port
            #
            # In the first case, the returned writer is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_writer('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The writer is automatically disconnected when the task quits
            def data_writer(*args)
                task, port_name, policy = data_accessor(*args)

                port = task.find_input_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no input port #{port_name}"
                end

                result = port.writer(policy)
                data_writers << result
                result
            end

            # call-seq:
            #   data_reader 'port_name'[, policy]
            #   data_reader 'role_name', 'port_name'[, policy]
            #
            # Returns a data reader that allows to read the specified port
            #
            # In the first case, the returned reader is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_reader('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The reader is automatically disconnected when the task quits
            def data_reader(*args)
                task, port_name, policy = data_accessor(*args)
                policy, other_policy = Kernel.filter_options policy, :pull => true
                policy.merge!(other_policy)

                port = task.find_output_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no output port #{port_name}"
                end

                result = port.reader(policy)
                data_readers << result
                result
            end

            on :stop do |event|
                data_writers.each do |writer|
                    if writer.connected?
                        writer.disconnect
                    end
                end
                data_readers.each do |reader|
                    if reader.connected?
                        reader.disconnect
                    end
                end
            end

            def method_missing(m, *args)
                return super if !args.empty? || block_given?

                if m.to_s =~ /^(\w+)_srv$/
                    service_name = $1
                    if service_model = find_data_service(service_name)
                        return service_model
                    else
                        raise NoMethodError, "#{self} has no service called #{service_name}"
                    end
                end
                super
            end

            # Returns a view of this component as a provider of the given
            # service model. It can for instance be used to connect ports while
            # transparently applying port mappings
            #
            # It works only if there is only one service providing the requested
            # type on +self+. Otherwise, one will have to select the service
            # first and only then call #as on the DataServiceInstance object
            #
            # The same can be done at the model level with Models::Component#as
            def as(service_model)
                return model.as(service_model).bind(self)
            end

	    # Resolves the given Syskit::Port object into a port object that
	    # points to the real task context port
            #
            # It should not be used directly. One should usually use
            # Port#to_actual_port instead
            #
            # @return [Syskit::Port]
            def self_port_to_actual_port(port)
		port
            end

            # Resolves the given Syskit::Port object into a Port object where
            # #component is guaranteed to be a proper component instance
            #
            # It should not be used directly. One should usually use
            # Port#to_component_port
            #
            # @param [Syskit::Port] port
            # @return [Syskit::Port] a port in which Port#component is
            #   guaranteed to be a proper component (e.g. not BoundDataService)
            def self_port_to_component_port(port)
                model.self_port_to_component_port(port.model).bind(self)
            end

            # Automatically computes connections from the output ports of self
            # to the given port or to the input ports of the given component
            #
            # (see Syskit.connect)
            def connect_to(port_or_component, policy = Hash.new)
                Syskit.connect(self, port_or_component, policy)
            end

            def bind(task)
                if !task.kind_of?(self)
                    raise TypeError, "cannot bind #{self} to #{task}"
                end
                task
            end

            # Requires a new dynamic service on this task context
            #
            # As {Models::Component#dynamic_service} already stated, the new
            # dynamic service is a description of what the task should provide.
            # One needs to reimplement the model's #configure method to actually
            # configure the task properly.
            #
            # @param (see Models::Component#require_dynamic_service)
            # @return [BoundDataService] the newly created service
            def require_dynamic_service(dynamic_service_name, as: nil, **dyn_options)
                specialize
                bound_service = self.model.require_dynamic_service(
                    dynamic_service_name, as: as, **dyn_options)
                srv = bound_service.bind(self)
                if plan && plan.executable? && setup?
                    added_dynamic_service(srv)
                end
                srv
            end

            # Hook called on an already-configured task when a new service got
            # added.
            #
            # Note that it will only happen for services whose 'dynamic' flag is
            # set (not the default)
            #
            # @param [BoundDynamicDataService] srv the newly created service
            # @return [void]
            # @see {#require_dynamic_service}
            def added_dynamic_service(srv)
                super if defined? super
            end

            # @deprecated has been renamed to {#each_required_dynamic_service}
            #   for consistency with the model-level method
            def each_dynamic_service(&block)
                each_required_dynamic_service(&block)
            end

            # Yields the data services that have been created through the
            # dynamic data service mechanism
            #
            # @yieldparam [BoundDataService] srv the data service generated
            #   using a dynamic data service. srv.model is an instance of
            #   {Models::BoundDynamicDataService} and srv.model.dynamic_service
            #   is the original dynamic data service (ouch !)
            # @return [void]
            def each_required_dynamic_service
                return enum_for(:each_dynamic_service) if !block_given?
                each_data_service do |srv|
                    if srv.model.respond_to?(:dynamic_service)
                        yield(srv)
                    end
                end
            end

            def specialized_model?
                concrete_model != model
            end

            # Sets up this task to use its singleton class as model instead of
            # the plain class. It is useful in particular for dynamic services
            def specialize
                if model != singleton_class
                    @model = singleton_class
                    model.name = self.class.name
                    model.concrete_model = self.class.concrete_model
                    model.private_specialization = true
                    model.private_model
                    self.class.setup_submodel(model)
                    true
                end
            end

            # Returns the most-derived model that is not a private specialization
            def concrete_model
                self.class.concrete_model
            end

            # Generates the InstanceRequirements object that represents +self+
            # best
            #
            # @return [Syskit::InstanceRequirements]
            def to_instance_requirements
                # Do not use #model here as we don't want a requirement that
                # uses a specialized model
                req = self.class.to_instance_requirements
                req.with_arguments(arguments.assigned_arguments)
                if required_host
                    req.on_server(required_host) 
                end
                req
            end

            # Returns a description of this task based on the dependency
            # information
            def dependency_context
                enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                    map do |parent_task|
                        options = parent_task[self,
                                              Roby::TaskStructure::Dependency]
                        [options[:roles].to_a.first, parent_task]
                    end
            end

            # Hook called when a connection will be created on an input port
            #
            # This is called *before* the connection gets established on the
            # underlying ports
            #
            # @param [Port] source_port
            # @param [Port] sink_port
            # @param [Hash] policy
            def adding_input_port_connection(source_port, sink_port, policy)
                super if defined? super
            end

            # Hook called when a connection has been created to an input port
            #
            # This is called *after* the connection has been established on the
            # underlying ports
            #
            # @param [Port] source_port
            # @param [Port] sink_port
            # @param [Hash] policy
            def added_input_port_connection(source_port, sink_port, policy)
                super if defined? super
            end

            # Hook called when a connection will be created on an output port
            #
            # This is called *before* the connection gets established on the
            # underlying ports
            #
            # @param [Port] source_port
            # @param [Port] sink_port
            # @param [Hash] policy
            def adding_output_port_connection(source_port, sink_port, policy)
                super if defined? super
            end

            # Hook called when a connection has been created to an output port
            #
            # This is called *after* the connection has been established on the
            # underlying ports
            #
            # @param [Port] source_port
            # @param [Port] sink_port
            # @param [Hash] policy
            def added_output_port_connection(source_port, sink_port, policy)
                super if defined? super
            end

            # Hook called when a connection will be removed from an input port
            #
            # This is called *before* the connection gets removed on the
            # underlying ports. It will be called only if this task is set up
            #
            # Unlike the add hooks, this does not deal with the syskit-level
            # representation of tasks, but with the underlying component
            # handler. The root cause of it is that disconnection can be
            # performed *after* a Roby task got finalized.
            #
            # @param [Orocos::TaskContext] source_task
            # @param [String] source_port
            # @param [String] sink_port
            def removing_input_port_connection(source_task, source_port, sink_port)
                super if defined? super
            end

            # Hook called when a connection has been removed from an input port
            #
            # This is called *after* the connection has been removed on the
            # underlying ports. It will be called only if this task is set up
            #
            # Unlike the add hooks, this does not deal with the syskit-level
            # representation of tasks, but with the underlying component
            # handler. The root cause of it is that disconnection can be
            # performed *after* a Roby task got finalized.
            #
            # @param [Orocos::TaskContext] source_task
            # @param [String] source_port
            # @param [String] sink_port
            def removed_input_port_connection(source_task, source_port, sink_port)
                super if defined? super
            end

            # Hook called when a connection will be removed from an output port
            #
            # This is called *before* the connection gets removed on the
            # underlying ports. It will be called only if this task is set up
            #
            # Unlike the add hooks, this does not deal with the syskit-level
            # representation of tasks, but with the underlying component
            # handler. The root cause of it is that disconnection can be
            # performed *after* a Roby task got finalized.
            #
            # @param [String] source_port
            # @param [Orocos::TaskContext] sink_task
            # @param [String] sink_port
            def removing_output_port_connection(source_port, sink_task, sink_port)
                super if defined? super
            end

            # Hook called when a connection has been removed from an output port
            #
            # This is called *after* the connection has been removed on the
            # underlying ports. It will be called only if this task is set up
            #
            # Unlike the add hooks, this does not deal with the syskit-level
            # representation of tasks, but with the underlying component
            # handler. The root cause of it is that disconnection can be
            # performed *after* a Roby task got finalized.
            #
            # @param [String] source_port
            # @param [Orocos::TaskContext] sink_task
            # @param [String] sink_port
            def removed_output_port_connection(source_port, sink_task, sink_port)
                super if defined? super
            end

            module Proxying
                proxy_for Component

                # Applies model specializations to the target task as well
                def commit_transaction
                    super if defined? super
                    if specialized_model?
                        __getobj__.specialize
                    end

                    # Merge the InstanceRequirements objects
                    __getobj__.requirements.merge(requirements)
                    __getobj__.duplicate_missing_services_from(self)
                end
            end
        end
end

