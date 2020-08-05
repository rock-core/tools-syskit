# frozen_string_literal: true

module Syskit
    Roby::EventStructure.relation "SyskitConfigurationPrecedence"

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

        provides AbstractComponent

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

        def initialize(**arguments)
            super
            @requirements = InstanceRequirements.new

            @registered_data_writers =
                instanciate_data_accessors(model.each_data_writer)
            @registered_data_readers =
                instanciate_data_accessors(model.each_data_reader)
            @data_readers = @registered_data_readers.values
            @data_writers = @registered_data_writers.values
        end

        def initialize_copy(source)
            super
            @requirements = @requirements.dup
            specialize if source.specialized_model?
            duplicate_missing_services_from(source)
        end

        def create_fresh_copy
            new_task = super
            new_task.robot = robot
            new_task
        end

        # @api private
        #
        # Creates the internal instanciated objects from the model-level data
        # accessors created with {Models::Component#data_reader} and
        # {Models::Component#data_writer}
        def instanciate_data_accessors(accessors)
            accessors.each_with_object({}) do |(name, object), h|
                h[name] = object.instanciate(self)
            end
        end

        # Whether this component instance is a placeholder for an abstract
        # combination of a component model and data services
        #
        # @see Models::Placeholder
        def placeholder?
            false
        end

        # Returns a set of hints that should be used to disambiguate the
        # deployment of this task.
        #
        # It looks for #deployment_hints in the requirements. If there are
        # none, it then looks in the parents.
        def deployment_hints
            hints = requirements.deployment_hints
            return hints unless hints.empty?

            result = Set.new
            each_parent_task do |p|
                result |= p.deployment_hints
            end
            result
        end

        # @api private
        #
        # Called by {InstanceRequirements#instanciate} to do post-processing
        # after a task has been instanciated from template
        #
        # The default is to simply assign the arguments.
        # {Composition#post_instanciation_setup} would for instance also
        # propagate its configuration to its children
        def post_instanciation_setup(**arguments)
            assign_arguments(**arguments)
        end

        # Returns the set of models this task fullfills
        def each_fullfilled_model(&block)
            model.each_fullfilled_model(&block)
        end

        # Yields the data services that are defined on this task
        def each_data_service
            return enum_for(:each_data_service) unless block_given?

            model.each_data_service do |_name, srv|
                yield(srv.bind(self))
            end
            self
        end

        def has_data_service?(service_name)
            model.find_data_service(service_name)
        end

        # Finds a data service by its name
        #
        # @param [String] service_name the data service name
        # @return [BoundDataService,nil] the found data service, or nil if
        #   there are no services with that name in self
        def find_data_service(service_name)
            model.find_data_service(service_name)&.bind(self)
        end

        # Finds a data service by its data service model
        #
        # @param [Model<DataService>] service_type the data service model
        #   we want to find in self
        # @return [BoundDataService,nil] the found data service, or nil if there
        #   are no services of that type in self
        # @raise (see Models::DataService#find_data_service_from_type)
        def find_data_service_from_type(service_type)
            model.find_data_service_from_type(service_type)&.bind(self)
        end

        # Declare that this component should not be configured until +event+
        # has been emitted. This is used to sequence configurations with
        # other system events, but should not be required in most cases
        def should_configure_after(object)
            # To make the scheduler happy
            should_start_after object
            object.add_syskit_configuration_precedence(start_event)
        end

        # Whether this task context will ever configurable
        def will_never_setup?
            false
        end

        def meets_configurationg_precedence_constraints?
            waiting_precedence_relation =
                start_event
                .parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence)
                .find { |event| !event.emitted? && !event.unreachable? }

            if waiting_precedence_relation
                debug do
                    "#{self} not ready for setup: "\
                    "waiting on #{waiting_precedence_relation}"
                end
            end

            !waiting_precedence_relation
        end

        # Returns true if the underlying Orocos task is in a state that
        # allows it to be configured
        def ready_for_setup? # :nodoc:
            if garbage?
                debug do
                    "#{self} not ready for setup: "\
                    "garbage collected but not yet finalized"
                end
                return false
            elsif !fully_instanciated?
                debug { "#{self} not ready for setup: not fully instanciated" }
                return false
            end

            meets_configurationg_precedence_constraints?
        end

        # Returns true if the underlying Orocos task has been properly
        # configured
        attr_predicate :setup?, true

        # Create a {Roby::Promise} object that configures the component
        #
        # Never overload this method. Overload {#perform_setup} instead.
        #
        # @return [Promise]
        def setup
            raise ArgumentError, "#{self} is already set up" if setup?

            promise = self.promise(description: "promise:#{self}#setup")
            perform_setup(promise)
            promise.on_error(description: "#{self}#setup#setup_failed!") do |e|
                setup_failed!(e)
            end
            promise.on_success(description: "#{self}#setup#setup_successful!") do
                setup_successful!
            end
            setting_up!(promise)
            promise
        end

        # @api private
        #
        # The actual setup operations. {#setup} is the user-facing part of
        # the setup API, which creates the promise and sets up the
        # setup-related bookkeeping operations
        def perform_setup(promise)
            promise.on_success(description: "#{self}#perform_setup#configure") do
                freeze_delayed_arguments
                model.prepare_stub(self) if model.needs_stub?(self)
                configure
            end
        end

        # @api private
        #
        # Called once at the beginning of a setup promise
        def setting_up!(promise)
            raise InvalidState, "#{self} is already setting up" if @setting_up

            @setting_up = promise
        end

        # @api private
        #
        # Called once the setup process is finished to mark the task as set
        # up
        def setup_successful!
            @setting_up = nil
            self.setup = true
        end

        # @api private
        #
        # Called when the setup process failed
        def setup_failed!(exception)
            if start_event.plan
                start_event.emit_failed(exception)
            else
                Roby.execution_engine.add_framework_error(
                    e, "#{self} got finalized before the setting_up! "\
                       "error handler was called"
                )
            end
            @setting_up = nil
        end

        # Whether the task is being set up
        def setting_up?
            @setting_up
        end

        # Controls whether the task can be removed from the plan
        #
        # Task context objects are kept while they're being set up, for the
        # sake of not breaking the setup process in an uncontrollable way.
        def can_finalize?
            !setting_up?
        end

        # User-provided part of the component configuration
        def configure
            super if defined? super
        end

        # Whether this task should be started only after all its inputs
        # have been connected
        def start_only_when_connected?
            true
        end

        # Test if the given task could be merged in self
        #
        # This method should only consider intrinsic criteria for the
        # merge, as e.g. compatibility of models or the value abstract? It
        # should never look into the task's neighborhood
        def can_merge?(task)
            unless super
                NetworkGeneration::MergeSolver.info(
                    "rejected: Component#can_merge? super returned false"
                )
                return
            end

            # Cannot merge if we are not reusable
            unless reusable?
                NetworkGeneration::MergeSolver.info(
                    "rejected: receiver is not reusable"
                )
                return
            end
            # We can not replace a non-abstract task with an
            # abstract one
            if !task.abstract? && abstract?
                NetworkGeneration::MergeSolver.info(
                    "rejected: cannot merge a non-abstract task into an abstract one"
                )
                return
            end
            true
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
            arguments.semantic_merge!(merged_task.arguments)

            # Merge the fullfilled model if set explicitely
            explicit_merged_fullfilled_model = merged_task.explicit_fullfilled_model
            explicit_this_fullfilled_model   = explicit_fullfilled_model
            if explicit_this_fullfilled_model && explicit_merged_fullfilled_model
                self.fullfilled_model =
                    Roby::TaskStructure::Dependency.merge_fullfilled_model(
                        explicit_merged_fullfilled_model,
                        [explicit_this_fullfilled_model[0]] +
                            explicit_this_fullfilled_model[1],
                        explicit_this_fullfilled_model[2]
                    )

            elsif explicit_merged_fullfilled_model
                self.fullfilled_model = explicit_merged_fullfilled_model.dup
            end

            # Merge the InstanceRequirements objects
            update_requirements(merged_task.requirements)

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
                unless srv.respond_to?(:dynamic_service)
                    raise InternalError,
                          "attempting to duplicate static service "\
                          "#{srv.name} from #{task} to #{self}"
                end

                dynamic_service_options = { as: srv.name }
                                          .merge(srv.dynamic_service_options)
                require_dynamic_service(
                    srv.dynamic_service.name,
                    **dynamic_service_options
                )
            end
        end

        # The set of data readers created with the string-based form of
        # {#data_reader}. Used to disconnect them when the task stops
        attr_reader :data_readers

        # The set of data writers created with the string-based form of
        # {#data_writer}. Used to disconnect them when the task stops
        attr_reader :data_writers

        # Enumerate this component's data readers
        #
        # @yieldparam [DataReaderInterface] reader
        def each_data_reader(&block)
            @data_readers.each(&block)
        end

        # Enumerate this component's data writers
        #
        # @yieldparam [DataWriterInterface] writer
        def each_data_writer(&block)
            @data_writers.each(&block)
        end

        # @api private
        #
        # Common implementation of port search for {#data_reader_by_role_path}
        # and {#data_writer_by_role_path}
        def data_accessor_resolve_port_from_role_path(*role_path, port_name)
            return port_by_name(port_name) if role_path.empty?

            component = role_path.inject(self) do |model, role|
                if model.respond_to?(:required_composition_child_from_role)
                    model.required_composition_child_from_role(role)
                else
                    model.child_from_role(role)
                end
            end
            component.port_by_name(port_name)
        end

        # @api private
        # @deprecated use {Models::Component#data_writer} or the object-based call
        #   to {#data_writer}
        #
        # Internal implementation of the deprecated string-based call to {#data_writer}
        #
        # Resolve a data writer by its name, possibly prefixing it with a role
        # path (a list of child names to the component that holds the port). If
        # the task is a composition, the method will attempt to map the port name
        # from the model's child (e.g. a service) to the actual component.
        #
        # @return [InputWriter]
        def data_writer_by_role_path(*role_path, port_name, **policy)
            port = data_accessor_resolve_port_from_role_path(
                *role_path, port_name
            )
            if port.output?
                raise ArgumentError,
                      "#{port} is an output port, expected an input port"
            end

            result = port.writer(**policy)
            data_writers << result
            result
        end

        # @api private
        #
        # Internal implementation of {#data_reader} and {#data_writer}
        def create_data_accessor(port, output:, as: nil, **policy)
            port_binding =
                Models::DynamicPortBinding
                .create(port)
                .instanciate

            if output ^ port_binding.output?
                direction = output ? "output" : "input"
                raise ArgumentError,
                      "expected #{port} to be an #{direction} port"
            end

            if as
                port_binding.to_bound_data_accessor(as, self, **policy)
            else
                port_binding.to_data_accessor(**policy)
            end
        end

        # Set of {DynamicPortBinding::BoundInputWriter} registered on self
        #
        # They are added on creation from {Models::Component#data_writers}, or
        # through {#data_writer}
        #
        # @return [{String=>DynamicPortBinding::BoundInputWriter}]
        attr_reader :registered_data_writers

        # Returns the {DynamicPortBinding::BoundInputWriter} with the given name if one
        # exists
        #
        # @return [DynamicPortBinding::BoundInputWriter,nil]
        def find_registered_data_writer(name)
            @registered_data_writers[name.to_str]
        end

        # Dynamically creates a {DynamicPortBinding::InputWriter} managed
        # by this component
        #
        # This is the dynamic version of {Models::Component#data_writer}.
        #
        # @param port one of this component's port, a composition child's port,
        #   or a {Queries::PortMatcher}. In the latter case, the port will be
        #   dynamically resolved at runtime within the plan this component is
        #   part of
        # @param [String] as the name under which this writer should be registered.
        #   Registered data writers can be accessed through a `#{name}_writer`
        #   accessor.
        #
        # @example
        #   # create an object that will dynamically bind and write to
        #   # the watchdog input port of a hypothetical running WatchdogUI
        #   # service
        #   data_writer Services::WatchdogUI.match.running.watchdog_port,
        #               as: 'watchdog'
        #
        #   # From now on, the writer is available through the watchdog_writer
        #   # accessor
        #   watchdog_writer.write(sample)
        #
        # @overload data_writer(port_name, **policy)
        #   @deprecated string-based form. See {#data_writer_by_role_path} for
        #       more information
        def data_writer(port, *args, as: nil, **policy)
            if port.respond_to?(:to_str)
                if as
                    raise ArgumentError,
                          "cannot provide the 'as' option to the deprecated "\
                          "string-based call to #data_writer"
                end

                return data_writer_by_role_path(port, *args, **policy)
            end

            writer = create_data_accessor(port, output: false, as: as, **policy)
            register_data_writer(writer, as: as)
            writer
        end

        # Register a data writer object compatible with {DataWriterInterface}
        #
        # @param [DataWriterInterface] reader
        # @param [String] as if non-nil, register it as a named writer that
        #    can be resolved through the _writer accessors and
        #    {#find_registered_data_writer}
        def register_data_writer(writer, as: nil)
            @data_writers << writer
            @registered_data_writers[as] = writer if as
            return unless running?

            writer.attach_to_task(self)
            writer.update
        end

        # Set of {DynamicPortBinding::BoundOutputReader} registered on self
        #
        # They are added on creation from {Models::Component#data_readers}, or
        # through {#data_reader}
        #
        # @return [{String=>DynamicPortBinding::BoundOutputReader}]
        attr_reader :registered_data_readers

        # Returns the {DynamicPortBinding::BoundOutputReader} with the
        # given name if one exists
        #
        # @return [DynamicPortBinding::BoundOutputReader,nil]
        def find_registered_data_reader(name)
            @registered_data_readers[name.to_str]
        end

        # @api private
        # @deprecated use {Models::Component#data_reader} or the object-based call
        #   to {#data_reader}
        #
        # Internal implementation of the deprecated string-based call to
        # {#data_reader}
        #
        # Resolve a data reader by its name, possibly prefixing it with a role
        # path (a list of child names to the component that holds the port). If
        # the task is a composition, the method will attempt to map the port name
        # from the model's child (e.g. a service) to the actual component.
        #
        # @return [OutputReader]
        def data_reader_by_role_path(*role_path, port_name, **policy)
            port = data_accessor_resolve_port_from_role_path(*role_path, port_name)
            unless port.output?
                raise ArgumentError,
                      "#{port} is an input port, expected an output port"
            end

            result = port.reader(**policy)
            data_readers << result
            result
        end

        # Dynamically creates a {DynamicPortBinding::OutputReader} managed
        # by this component
        #
        # This is the dynamic version of {Models::Component#data_reader}.
        #
        # @param port one of this component's port, a composition child's port,
        #   or a {Queries::PortMatcher}. In the latter case, the port will be
        #   dynamically resolved at runtime within the plan this component is
        #   part of
        #
        # @example
        #   # create an object that will dynamically bind and read from
        #   # the position output port of a hypothetical running ReferencePosition
        #   # service
        #   data_writer Services::ReferencePosition.match.running.position_port,
        #               as: 'position'
        #
        #   # From now on, the writer is available through the watchdog_writer
        #   # accessor
        #   position_port.read_new
        #
        # @overload data_reader(port_name, **policy)
        #   @deprecated string-based form. See {#data_reader_by_role_path} for
        #       more information
        def data_reader(port, *args, as: nil, pull: true, **policy)
            if port.respond_to?(:to_str)
                if as
                    raise ArgumentError,
                          "cannot provide the 'as' option to the deprecated "\
                          "string-based call to #data_reader"
                end

                return data_reader_by_role_path(port, *args, pull: pull, **policy)
            end

            reader = create_data_accessor(
                port, output: true, as: as, pull: pull, **policy
            )
            register_data_reader(reader, as: as)
            reader
        end

        # Register a data reader object compatible with {DataReaderInterface}
        #
        # @param [DataReaderInterface] reader
        # @param [String] as if non-nil, register it as a named reader that
        #    can be resolved through the _reader accessors and
        #    {#find_registered_data_reader}
        def register_data_reader(reader, as: nil)
            @data_readers << reader
            @registered_data_readers[as] = reader if as
            return unless running?

            reader.attach_to_task(self)
            reader.update
        end

        on :start do |_event|
            @data_readers.each do |reader|
                reader.attach_to_task(self) if reader.respond_to?(:attach_to_task)
            end
            @data_writers.each do |writer|
                writer.attach_to_task(self) if writer.respond_to?(:attach_to_task)
            end
        end

        poll do
            @data_readers.each do |reader|
                reader.update if reader.respond_to?(:update)
            end
            @data_writers.each do |writer|
                writer.update if writer.respond_to?(:update)
            end
        end

        on :stop do |_event|
            @data_writers.each(&:disconnect)
            @data_readers.each(&:disconnect)
        end

        def has_through_method_missing?(m)
            MetaRuby::DSLs.has_through_method_missing?(
                self, m,
                "_srv" => :has_data_service?,
                "_writer" => :find_registered_data_writer,
                "_reader" => :find_registered_data_reader
            ) || super
        end

        def find_through_method_missing(m, args)
            MetaRuby::DSLs.find_through_method_missing(
                self, m, args,
                "_srv" => :find_data_service,
                "_writer" => :find_registered_data_writer,
                "_reader" => :find_registered_data_reader
            ) || super
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
            model.as(service_model).bind(self)
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
        def connect_to(port_or_component, policy = {})
            Syskit.connect(self, port_or_component, policy)
        end

        def bind(task)
            raise TypeError, "cannot bind #{self} to #{task}" unless task.kind_of?(self)

            task
        end

        def update_requirements(new_requirements, name: nil, keep_abstract: false)
            requirements.name = name if name
            requirements.merge(new_requirements, keep_abstract: keep_abstract)
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
        def require_dynamic_service(dynamic_service_name, as:, **dyn_options)
            specialize
            bound_service = model.require_dynamic_service(
                dynamic_service_name, as: as, **dyn_options
            )
            srv = bound_service.bind(self)
            added_dynamic_service(srv) if plan&.executable? && setup?
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
            return enum_for(:each_dynamic_service) unless block_given?

            each_data_service do |srv|
                yield(srv) if srv.model.respond_to?(:dynamic_service)
            end
        end

        def specialized_model?
            concrete_model != model
        end

        # Sets up this task to use its singleton class as model instead of
        # the plain class. It is useful in particular for dynamic services
        def specialize
            return if model == singleton_class

            @model = singleton_class
            model.name = self.class.name
            model.concrete_model = self.class.concrete_model
            model.private_specialization = true
            model.private_model
            self.class.setup_submodel(model)
            true
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
            req.with_arguments(**arguments.assigned_arguments)
            req.on_server(required_host) if required_host
            req
        end

        # Returns a description of this task based on the dependency
        # information
        def dependency_context
            enum_for(:each_parent_object, Roby::TaskStructure::Dependency)
                .map do |parent_task|
                    options = parent_task[
                        self,
                        Roby::TaskStructure::Dependency
                    ]
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
                __getobj__.specialize if specialized_model?

                # Merge the InstanceRequirements objects
                __getobj__.update_requirements(requirements)
                __getobj__.duplicate_missing_services_from(self)
            end
        end

        # Definition of the interface expected for elements of {#data_readers}
        # and {#data_writers}
        #
        # This is meant as documentation, in case you wish to implement your own
        #
        # You do *not* need to subclass this
        class DataAccessorInterface
            # Calls once at the beginning to identify the reader "attachment point"
            #
            # For some readers, the task's plan is what is being used. For
            # others, task itself has meaning
            def attach_to_task(task); end

            # Calls once just after #attach_to_task, and then repeatedly
            #
            # This method should
            def update; end

            # Called at the end to release resources
            def disconnect; end
        end
    end
end
