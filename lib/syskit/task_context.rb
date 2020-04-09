# frozen_string_literal: true

module Syskit
    # In the orocos/rtt, a task context is what is usually called a
    # component.
    #
    # Subclasses of TaskContext represent these components in Roby plans, an
    # TaskContext instances may be associated with a Deployment task, that
    # represent the underlying deployment process. The link between a task
    # context and its deployment is usually represented by an executed_by
    # relation.
    #
    # The task configuration step is managed as follows:
    #
    # * all tasks start with executable? and setup? returning false
    # * the engine will call #setup to configure the task if it is in the
    #   main plan. If the actual orocos task was already setup, #setup will
    #   actually do nothing. At this stage, executable? is still false
    # * executable? will be true only if the task is configured *and* all
    #   static inputs are connected.
    class TaskContext < Component
        extend Models::TaskContext

        extend Logger::Hierarchy
        include Logger::Hierarchy

        # TaskContext uses the Robot for logging by default
        self.logger = ::Robot.logger

        root_model
        abstract

        # The task's configuration, as a list of registered configurations
        # for the underlying task context
        #
        # For instance ['default', 'left_camera'] will apply the 'default'
        # section of config/orogen/orogen_project::TaskClassName.yml and
        # then override with the 'left_camera' section of the same file
        argument :conf, :default => ["default"]
        # The name of the remote task context, i.e. the name under which it
        # can be resolved by Orocos.name_service
        argument :orocos_name

        # [Orocos::TaskContext,Orocos::ROS::Node] the underlying remote task
        # context object. It is set only when the task context's deployment
        # is running
        attr_reader :orocos_task
        # [Orocos::Generation::TaskDeployment] the model of this deployment
        attr_accessor :orogen_model
        # The current state for the orogen task. It is a symbol that
        # represents the state name (i.e. :RUNTIME_ERROR, :RUNNING, ...)
        attr_reader :orogen_state
        # The last state before we went to orogen_state
        attr_reader :last_orogen_state

        # @api private
        #
        # Initialize the communication with the remote task
        #
        # @param [Deployment::RemoteTaskHandles] remote_handles
        def initialize_remote_handles(remote_handles)
            @orocos_task       = remote_handles.handle
            @orocos_task.model = model.orogen_model
            @state_reader      = remote_handles.state_reader

            remote_handles.default_properties.each do |p, p_value|
                syskit_p = property(p.name)
                syskit_p.remote_property = p
                syskit_p.update_remote_value(p_value)
                syskit_p.update_log_metadata(p.log_metadata)
                unless syskit_p.has_value?
                    syskit_p.write(p_value)
                end
            end
        end

        # @!attribute r tid
        #   @return [Integer] The thread ID of the thread running this task
        #   Beware, the thread might be on a remote machine !
        def tid
            orocos_task.tid
        end

        # Returns the task's event name that maps to the given component state name
        #
        # @return [Symbol]
        def state_event(name)
            model.find_state_event(name)
        end

        # Maximum time between the task is sent a trigger signal and the
        # time it is actually triggered
        def trigger_latency
            orogen_model.worstcase_trigger_latency
        end

        def trigger_latency=(latency)
            orogen_model.worstcase_trigger_latency = latency
        end

        def initialize(orogen_model: nil, **arguments)
            super(**arguments)

            @orogen_model = orogen_model ||
                Orocos::Spec::TaskDeployment.new(nil, model.orogen_model)

            properties = {}
            property_overrides = {}
            model.orogen_model.each_property do |p|
                type = Roby.app.default_loader.intermediate_type_for(p.type)
                properties[p.name] = LiveProperty.new(self, p.name, type)
                property_overrides[p.name] = Property.new(p.name, type)
            end
            @properties = Properties.new(self, properties)
            @property_overrides = Properties.new(self, property_overrides)

            @current_property_commit = nil

            @setup = false
            @ready_to_start = false
            @required_host = nil
            # This is initalized to one as we known that {#setup} will
            # perform a property update
            @has_pending_property_updates = true
        end

        def create_fresh_copy # :nodoc:
            new_task = super
            new_task.orocos_task  = orocos_task
            new_task.orogen_model = orogen_model
            new_task
        end

        # Whether this task context can be started
        #
        # Under syskit, this can happen only if the task has been setup
        # *and* all its inputs are connected
        def executable?
            @executable || (@ready_to_start && super)
        end

        # Whether the task should be kept in plan
        def can_finalize?
            super &&
                (!(promise = @current_property_commit) ||
                   promise.complete?)
        end

        # Value returned by TaskContext#distance_to when the tasks are in
        # the same process
        D_SAME_PROCESS = Orocos::OutputPort::D_SAME_PROCESS
        # Value returned by TaskContext#distance_to when the tasks are in
        # different processes, but on the same machine
        D_SAME_HOST = Orocos::OutputPort::D_SAME_HOST
        # Value returned by TaskContext#distance_to when the tasks are in
        # different processes localized on different machines
        D_DIFFERENT_HOSTS = Orocos::OutputPort::D_DIFFERENT_HOSTS

        # How "far" this process is from the Syskit process
        #
        # @return one of the {TaskContext}::D_* constants
        def distance_to_syskit
            execution_agent.distance_to_syskit
        end

        # Whether this task runs within the Syskit process itself
        def in_process?
            execution_agent.in_process?
        end

        # Whether this task runs on the same host than the Syskit process
        def on_localhost?
            execution_agent.on_localhost?
        end

        # Returns a value that represents how the two task contexts are far
        # from each other. The possible return values are:
        #
        # nil::
        #   one or both of the tasks are not deployed
        # D_SAME_PROCESS::
        #   both tasks are in the same process
        # D_SAME_HOST::
        #   both tasks are in different processes, but on the same machine
        # D_DIFFERENT_HOSTS::
        #   both tasks are in different processes localized on different
        #   machines
        def distance_to(other)
            return if !execution_agent || !other.execution_agent

            execution_agent.distance_to(other.execution_agent)
        end

        # Verifies if a task could be replaced by this one
        #
        # @return [Boolean] true if #merge(other_task) can be called and
        # false otherwise
        def can_merge?(other_task) # :nodoc:
            return unless super

            # Verify the host constraints (i.e. can't merge other_task in
            # +self+ if both have constraints on which host they should run,
            # and that constraint does not match)
            result = other_task.respond_to?(:required_host) &&
                (!required_host || !other_task.required_host ||
                required_host == other_task.required_host)

            if !result
                NetworkGeneration.debug { "cannot merge #{other_task} in #{self}: different host constraints" }
                false
            else
                true
            end
        end

        # (see Component#can_be_deployed_by?)
        def can_be_deployed_by?(task)
            # NOTE: in the two tests below, we use the fact that
            # {#can_merge?} (and therefore {Component#can_be_deployed_by?})
            # already checked that services that have the same name in task
            # and self are actually of identical definition.

            return false unless super

            # First check if there are services that need to be removed.
            # Syskit doesn't support that, so for those we cannot deploy
            # using 'task'
            task.each_required_dynamic_service do |srv|
                if srv.model.remove_when_unused? && !find_data_service(srv.name)
                    return false
                end
            end

            # Now check for new services that would require reconfiguration
            # when added. Unlike with remove_when_unused, if 'task' is not
            # setup, we can add the new data services to 'task' and
            # therefore ignore the differences
            return true unless task.setup?

            each_required_dynamic_service do |srv|
                if srv.model.addition_requires_reconfiguration? && !task.find_data_service(srv.name)
                    return false
                end
            end

            true
        end

        # Replaces the given task by this task
        #
        # @param [TaskContext] merged_task the task that should be replaced
        # @return [void]
        def merge(merged_task)
            super
            self.required_host ||= merged_task.required_host

            if merged_task.orogen_model && !orogen_model
                self.orogen_model = merged_task.orogen_model
            end

            if merged_task.orocos_task && !orocos_task
                self.orocos_task = merged_task.orocos_task
            end
            nil
        end

        def deployment_hints
            hints = requirements.deployment_hints.to_set.dup
            return hints unless hints.empty?

            if respond_to?(:each_master_device)
                each_master_device do |dev|
                    hints |= dev.requirements.deployment_hints.to_set
                end
            end
            return hints unless hints.empty?

            super
        end

        def operation(name)
            orocos_task.operation(name)
        end

        # Accessor for the task's properties
        #
        # @example write a property named 'latency'
        #    task.properties.latency = 20
        # @example read the syskit-side value of the latency property
        #    task.properties.latency # => 20
        # @example update a complex type
        #    task.properties.position do |p|
        #       p.x = 10
        #       p.y = 20
        #       p.z = 30
        #       p
        #    end
        attr_reader :properties

        # Accessor for overrides of the configuration values
        #
        # This is an accessor that works akin to {#properties}. It is used
        # to set values that will override the values in the configuration
        # files at {#configure} time
        #
        # The expected configuration can later be restored with
        # {#property_overrides}
        #
        # @see clear_property_overrides
        attr_reader :property_overrides

        # Enumerate this task's known properties
        def each_property(&block)
            properties.each(&block)
        end

        # Whether this task has a property with the given name
        def has_property?(name)
            properties.include?(name)
        end

        # Returns the syskit-side representation of the given property
        #
        # Properties in Syskit are applied only at configuration time, or
        # when #commit_properties is called
        def property(name)
            name = name.to_s
            if (p = find_property(name))
                p
            else
                raise Orocos::InterfaceObjectNotFound.new(self, name), "#{self} has no property called #{name}"
            end
        end

        # Resolves a property by name
        #
        # @param [String] name
        def find_property(name)
            properties[name.to_str]
        end

        # Event emitted when a property commit has successfully finished
        event :properties_updated

        def would_use_property_update?
            pending? || starting? || (running? && !finishing?)
        end

        # @api private
        #
        # Queue a remote property update if none are pending
        #
        # This is used by {Property} on writes. Note that because of the
        # general property update structure, all property updates happening
        # in a single execution cycle will be committed together.
        def queue_property_update_if_needed
            unless would_use_property_update?
                raise InvalidState,
                      "attempting to queue a property update on a finished "\
                      "or finishing task"
            end

            return if @has_pending_property_updates

            commit_properties.execute
        end

        # Create a promise that will apply the properties stored Syskit-side
        # to the underlying component, but only if the underlying task would
        # have a use for it (e.g. it is running or pending)
        #
        # It returns a null promise otherwise.
        #
        # @example apply the next property updates and emit the event once
        #   the properties have been applied, but do not do it if the
        #   underlying task is finished
        #
        #   updated_configuration_event.achieve_asynchronously(
        #       my_child.commit_properties_if_needed)
        #   # Do the property updates
        #
        # @return [Roby::Promise,Roby::Promise::Null]
        # @see commit_properties
        def commit_properties_if_needed(*args)
            if would_use_property_update?
                commit_properties(*args)
            else
                Roby::Promise.null
            end
        end

        # Create a promise that will apply the properties stored Syskit-side
        # to the underlying component
        #
        # This usually does not need to be called, as Syskit queues a
        # property update at the component configuration, and whenever a
        # property gets updated
        #
        # @return [Roby::Promise]
        def commit_properties(promise = self.promise(description: "promise:#{self}#commit_properties"))
            promise.on_success(description: "#{self}#commit_properties#init") do
                if finalized? || garbage? || finishing? || finished?
                    []
                else
                    # NOTE: {#queue_property_update_if_needed}, is a
                    # *delayed* property commit. It attempts at doing one
                    # batched write for many writes from Property#write.
                    #
                    # This works because the property-snapshot step (this
                    # step) is done within the event loop.

                    # Register this as the active property commit
                    # for the benefit of {#handle_state_change} and
                    # synchronizing with the task stop
                    @current_property_commit = promise

                    # Reset to false (allowing commit queueing from
                    # Property#write) only if the task is starting and/or
                    # running. This is because we explicitely commit
                    # properties within the setup step, and within the
                    # task's start event.
                    @has_pending_property_updates = !(starting? || running?)

                    each_property.map do |p|
                        if p.needs_commit?
                            [p, p.value.dup]
                        end
                    end.compact
                end
            end
            promise.then(description: "#{self}#commit_properties#write") do |properties|
                properties.map do |p, p_value|
                    begin
                        p.remote_property.write(p_value)
                        [Time.now, p, nil]
                    rescue ::Exception => e
                        [Time.now, p, e]
                    end
                end.compact
            end.on_success(description: "#{self}#commit_properties#update_log") do |result|
                result.map do |timestamp, property, error|
                    if error
                        execution_engine.add_error(PropertyUpdateError.new(error, property))
                    else
                        property.update_remote_value(property.value)
                        property.update_log(timestamp)
                        property
                    end
                end.compact
            end

            @has_pending_property_updates = true
            promise
        end

        # If true, the current state (got from the component's state port)
        # is compared with the RTT state as reported by
        # the task itself through a port.
        #
        # This should only be used for debugging reasons, and if you know
        # what you are doing: inconsistencies can arise because the state
        # port is an asynchronous mean of communication while #rtt_state is
        # synchronous
        attr_predicate :validate_orogen_states, true

        # Validates that the current value in #orogen_state matches the
        # value returned by orocos_task.rtt_state. This is called
        # automatically if #validate_orogen_states? is set to true
        def validate_orogen_state_from_rtt_state
            orogen_state = orogen_state
            rtt_state    = orocos_task.rtt_state
            mismatch =
                case rtt_state
                when :RUNNING
                    !orocos_task.runtime_state?(orogen_state)
                when :STOPPED
                    orogen_state != :STOPPED
                when :RUNTIME_ERROR
                    !orocos_task.error_state?(orogen_state)
                when :FATAL_ERROR
                    !orocos_task.fatal_error_state?(orogen_state)
                when :EXCEPTION
                    !orocos_task.exception_state?(orogen_state)
                end

            if mismatch
                Runtime.warn "state mismatch on #{self} between state=#{orogen_state} and rtt_state=#{rtt_state}"
                @orogen_state = rtt_state
                handle_state_changes
            end
        end

        # The state reader object used to get state updates from the task
        #
        # @return [Orocos::TaskContext::StateReader]
        attr_reader :state_reader

        # Called at each cycle to update the orogen_state attribute for this
        # task using the values read from the state reader
        def update_orogen_state
            @state_sample ||= state_reader.new_sample
            result, v = state_reader.read_with_result(@state_sample, false)
            if !result
                unless state_reader.connected?
                    fatal "terminating #{self}, its state reader #{state_reader} is disconnected"
                    aborted!
                end
                nil
            elsif v
                @last_orogen_state = @orogen_state
                @orogen_state = v
            end
        end

        # @api private
        #
        # Pull all state changes that are still queued within the state
        # reader and returns the last one
        #
        # It is destructive, as it does "forget" any pending state changes
        # currently queued.
        def read_current_state
            while (new_state = state_reader.read_new)
                state = new_state
            end
            state || state_reader.read
        end

        # Whether this task context will ever be configurable
        def will_never_setup?(state = nil)
            state ||= read_current_state
            state == :FATAL_ERROR
        end

        CONFIGURABLE_RTT_STATES = %I[STOPPED PRE_OPERATIONAL].freeze

        # Returns true if this component needs to be setup by calling the
        # #setup method, or if it can be used as-is
        def ready_for_setup?(state = nil)
            if execution_agent.configuring?(orocos_name)
                debug { "#{self} not ready for setup: already configuring" }
                return false
            elsif !super()
                return false
            elsif !all_inputs_connected?(only_static: true)
                debug { "#{self} not ready for setup: some static ports are not connected" }
                return false
            elsif !orogen_model || !orocos_task
                debug { "#{self} not ready for setup: no orogen model or no orocos task" }
                return false
            end

            unless state ||= read_current_state
                debug do
                    "#{self} not ready for setup: not yet received current state"
                end
                return
            end

            configurable_state =
                CONFIGURABLE_RTT_STATES.include?(state) ||
                orocos_task.exception_state?(state)
            if configurable_state
                true
            else
                debug do
                    "#{self} not ready for setup: in state #{state}, "\
                    "expected STOPPED, PRE_OPERATIONAL or an exception state"
                end
                false
            end
        end

        # Returns true if the underlying Orocos task has been configured and
        # can be started
        #
        # The general protocol is:
        #
        #  if !setup? && ready_for_setup?
        #      setup
        #  end
        #
        def setup?
            @setup
        end

        def ready_to_start!
            @ready_to_start = true
        end

        # Announces that the task is indeed setup
        #
        # This is meant for internal use. Don't use it unless you know what
        # you are doing
        def setup_successful!
            execution_agent.update_current_configuration(
                orocos_name, model, conf.dup, each_required_dynamic_service.to_set
            )
            execution_agent.finished_configuration(orocos_name)

            if all_inputs_connected?
                ready_to_start!
                execution_engine.scheduler.report_action "configured and all inputs connected, marking as executable", self
                Runtime.debug { "#{self} is setup and all its inputs are connected, executable? = #{executable?}" }
            else
                execution_engine.scheduler.report_action "configured, but some connections are pending", self
                Runtime.debug { "#{self} is setup but some of its inputs are not connected, executable = #{executable?}" }
            end
            super
        end

        # If true, #configure must be called on this task before it is
        # started. This flag is reset after #configure has been called
        def needs_reconfiguration?
            execution_agent&.needs_reconfiguration?(orocos_name)
        end

        # Make sure that #configure will be called on this task before it
        # gets started
        #
        # See also #setup and #needs_reconfiguration?
        def needs_reconfiguration!
            execution_agent&.needs_reconfiguration!(orocos_name)
        end

        # Tests if this task can be reused in the next deployment run
        def reusable?
            super && (!setup? || !needs_reconfiguration?)
        end

        # Remove connections manually to the dynamic ports
        #
        # This is called after orocos_task.cleanup, as a task's cleanupHook
        # is supposed to delete all dynamic ports (and therefore disconnect
        # them)
        def clean_dynamic_port_connections(port_names)
            to_remove = {}
            to_remove.merge!(dynamic_input_port_connections(port_names))
            to_remove.merge!(dynamic_output_port_connections(port_names))
            relation_graph_for(Flows::DataFlow).modified_tasks << self
            to_remove.each do |(source_task, sink_task), connections|
                ActualDataFlow.remove_connections(source_task, sink_task, connections)
            end
        end

        # @api private
        #
        # Helper for {#prepare_for_setup} that enumerates the inbound
        # connections originating from a dynamic output port
        def dynamic_input_port_connections(existing_port_names)
            to_remove = {}
            real_model = model.concrete_model
            dynamic_ports = model.each_input_port.find_all do |p|
                !real_model.find_input_port(p.name)
            end
            dynamic_ports = dynamic_ports.map(&:name).to_set

            dynamic_ports.each do |name|
                if existing_port_names.include?(name)
                    Syskit.fatal "task #{orocos_task} did not clear #{name}, a dynamic input port, during cleanup, as it should have. Go fix it."
                end
            end

            ActualDataFlow.each_in_neighbour(orocos_task) do |source_task|
                mappings = ActualDataFlow.edge_info(source_task, orocos_task)
                to_remove[[source_task, orocos_task]] = mappings.each_key.find_all do |from_port, to_port|
                    dynamic_ports.include?(to_port)
                end
            end
            to_remove
        end

        # @api private
        #
        # Helper for {#prepare_for_setup} that enumerates the outbound
        # connections originating from a dynamic output port
        def dynamic_output_port_connections(existing_port_names)
            to_remove = {}
            real_model = model.concrete_model
            dynamic_ports = model.each_output_port.find_all do |p|
                !real_model.find_output_port(p.name)
            end
            dynamic_ports = dynamic_ports.map(&:name).to_set

            dynamic_ports.each do |name|
                if existing_port_names.include?(name)
                    Syskit.fatal "task #{orocos_task} did not clear #{name}, a dynamic output port, during cleanup, as it should have. Go fix it."
                end
            end

            ActualDataFlow.each_out_neighbour(orocos_task) do |sink_task|
                mappings = ActualDataFlow.edge_info(orocos_task, sink_task)
                to_remove[[orocos_task, sink_task]] = mappings.each_key.find_all do |from_port, to_port|
                    dynamic_ports.include?(from_port)
                end
            end
            to_remove
        end

        # @api private
        #
        # Setup operations that must be performed before
        # {Component#perform_setup} is called by {#perform_setup}
        def prepare_for_setup(promise)
            promise.then(description: "#{self}#prepare_for_setup#read_properties") do
                properties = each_property.map do |syskit_p|
                    [syskit_p, syskit_p.remote_property.raw_read]
                end
                [properties, orocos_task.rtt_state]
            end.on_success(description: "#{self}#prepare_for_setup#write properties and needs_reconfiguration") do |properties, state|
                properties.each do |syskit_p, remote_value|
                    syskit_p.update_remote_value(remote_value)
                end

                needs_reconfiguration = needs_reconfiguration? ||
                    execution_agent.configuration_changed?(
                        orocos_name, conf, each_required_dynamic_service.to_set
                    ) ||
                    self.properties.each.any?(&:needs_commit?)

                unless needs_reconfiguration
                    info "not reconfiguring #{self}: the task is already configured as required"
                end
                [needs_reconfiguration, state]
            end.then(description: "#{self}#prepare_for_setup#ensure_pre_operational") do |needs_reconfiguration, state|
                if state == :EXCEPTION
                    info "reconfiguring #{self}: the task was in exception state"
                    orocos_task.reset_exception(false)
                    orocos_task.port_names
                elsif needs_reconfiguration && (state != :PRE_OPERATIONAL)
                    info "cleaning up #{self}"
                    orocos_task.cleanup(false)
                    orocos_task.port_names
                end
            end.on_success(description: "#{self}#prepare_for_setup#clean_dynamic_port_connections") do |port_names|
                if port_names
                    clean_dynamic_port_connections(port_names)
                end
            end
        end

        # (see Component#perform_setup)
        def perform_setup(promise)
            prepare_for_setup(promise)
            # This calls #configure
            super(promise)

            properties_updated_in_configure = false
            promise.on_success(description: "#{self}#perform_setup#log_properties") do
                model.prepare_stub(self) if model.needs_stub?(self)
                if Syskit.conf.logs.conf_logs_enabled?
                    each_property do |p|
                        p.log_stream = Syskit.conf.logs.log_stream_for(p)
                        p.update_log
                    end
                end
                properties_updated_in_configure =
                    properties.each.any?(&:needs_commit?)
            end
            commit_properties(promise)
            promise.then(description: "#{self}#perform_setup#orocos_task.configure") do
                state = orocos_task.rtt_state
                if properties_updated_in_configure && state != :PRE_OPERATIONAL
                    info "properties have been changed within #configure, "\
                         "cleaning up #{self}"
                    orocos_task.cleanup(false)
                    state = :PRE_OPERATIONAL
                end

                if state == :PRE_OPERATIONAL
                    info "setting up #{self}"
                    orocos_task.configure(false)
                else
                    info "#{self} was already configured"
                end
            end
        end

        # (see Component#setting_up!)_
        def setting_up!(promise)
            super
            execution_agent.start_configuration(orocos_name)
        end

        # (see Component#setup_failed!)_
        def setup_failed!(exception)
            execution_agent.finished_configuration(orocos_name)
            super
        end

        # Returns the start event object for this task

        # Optionally configures and then start the component. The start
        # event will be emitted when the it has successfully been
        # configured and started.
        event :start do |context|
            info "starting #{self}"
            @last_orogen_state = nil

            state_reader.resume if state_reader.respond_to?(:resume)

            expected_output_ports = each_concrete_output_connection
                                    .map { |port_name, _| port_name }
            expected_input_ports = each_concrete_input_connection
                                   .map { |_, _, port_name, _| port_name }
            promise = promise(description: "promise:#{self}#start")
            commit_properties(promise)
            promise.then do
                port_names = orocos_task.port_names.to_set
                # At this point, we should have already created all the
                # dynamic ports that are required ... check that
                expected_output_ports.each do |source_port|
                    unless port_names.include?(source_port)
                        raise Orocos::NotFound,
                              "#{orocos_name}(#{orogen_model.name}) does "\
                              "not have a port named #{source_port}"
                    end
                end
                expected_input_ports.each do |sink_port|
                    unless port_names.include?(sink_port)
                        raise Orocos::NotFound,
                              "#{orocos_name}(#{orogen_model.name}) does "\
                              "not have a port named #{sink_port}"
                    end
                end
                orocos_task.start(false)
            end
            start_event.achieve_asynchronously(promise, emit_on_success: false)
        end

        # Handle a state transition by emitting the relevant events
        def handle_state_changes # :nodoc:
            # If we are starting, we should ignore all states until a
            # runtime state is found
            unless @got_running_state
                return unless orocos_task.runtime_state?(orogen_state)

                @got_running_state = true
                @last_terminal_state = nil
                start_event.emit
            end

            if orocos_task.runtime_state?(orogen_state)
                if last_orogen_state && orocos_task.error_state?(last_orogen_state)
                    running_event.emit
                elsif @last_terminal_state
                    fatal "#{self} reports state #{orogen_state} after having "\
                          "reported a terminal state (#{@last_terminal_state}). "\
                          "Syskit will try to go on, but this should not happen."
                end
            end

            state_event =
                if orogen_state == :STOPPED
                    if interrupt_event.pending?
                        interrupt_event
                    elsif finishing?
                        stop_event
                    else
                        success_event
                    end
                elsif orogen_state != :RUNNING
                    if event_name = state_event(orogen_state)
                        event(event_name)
                    else
                        raise ArgumentError,
                              "#{self} reports state #{orogen_state}, "\
                              "but I don't have an event for this state transition"
                    end
                end

            return unless state_event

            if state_event.terminal?
                # This is needed so that the first step of
                # @current_property_commit cancels the promise.
                self.finishing = true

                # If there's a pending property commit, we must wait for it
                # to finish before emitting the event
                if (promise = @current_property_commit) && !promise.complete?
                    promise.add_observer do
                        execution_engine.execute(type: :propagation) do
                            state_event.emit
                        end
                    end
                else
                    state_event.emit
                end
                @last_terminal_state = orogen_state

            elsif orogen_state != :RUNNING
                state_event.emit
            end
        end

        # @api private
        #
        # Helper method that is called in a separate thread to stop the
        # orocos task, taking into account some corner cases such as a dead
        # task, or a task that raises StateTransitionFailed but stops
        # anyways
        def stop_orocos_task
            orocos_task.stop(false)
            nil
        rescue Orocos::ComError
            # We actually aborted. Notify the callback so that it emits
            # interrupt and stop
            :aborted
        rescue Orocos::StateTransitionFailed
            # Use #rtt_state as it has no problem with asynchronous
            # communication, unlike the port-based state updates.
            state = orocos_task.rtt_state
            raise if state == :RUNNING

            Runtime.debug { "in the interrupt event, StateTransitionFailed: task.state == #{state}" }
            # Nothing to do, the poll block will finalize the task
            nil
        end

        # Interrupts the execution of this task context
        event :interrupt do |context|
            info "interrupting #{self}"

            if !orocos_task # already killed
                interrupt_event.emit
                aborted_event.emit
            elsif execution_agent && !execution_agent.finishing?
                promise = execution_engine
                          .promise(description: "promise:#{self}#interrupt") do
                              stop_orocos_task
                          end
                          .on_success(description: "#{self}#interrupt#done") do |result|
                    if result == :aborted
                        interrupt_event.emit
                        aborted_event.emit
                    end
                end

                interrupt_event.achieve_asynchronously(promise, emit_on_success: false)
            end
        end

        forward :interrupt => :failed

        # @!method running_event
        #
        # Returns the running event object for this task. This event gets
        # emitted whenever the component goes into the Running state, either
        # because it has just been started or because it left a runtime
        # error state.

        # @!method runtime_error_event
        #
        # Returns the runtime error event object for this task. This event
        # gets emitted whenever the component goes into a runtime error
        # state.

        # @!method exception_event
        #
        # Returns the exception error event object for this task. This event
        # gets emitted whenever the component goes into an exception
        # state.

        # @!method fatal_error_event
        #
        # Returns the fatal error event object for this task. This event
        # gets emitted whenever the component goes into a fatal error state.
        #
        # This leads to the component emitting both :failed and :stop

        forward :start => :running
        forward :exception => :failed
        forward :fatal_error => :failed
        on :fatal_error do |_event|
            kill_execution_agent_if_alone
        end

        def kill_execution_agent_if_alone
            if execution_agent
                not_loggers = execution_agent
                              .each_executed_task
                              .find_all { |t| !Roby.app.syskit_utility_component?(t) }
                if not_loggers.size == 1
                    plan.unmark_permanent_task(execution_agent)
                    if execution_agent.running?
                        execution_agent.stop!
                        return true
                    end
                end
            end
            false
        end

        event :aborted, terminal: true do |_context|
            if execution_agent&.running? && !execution_agent.finishing?
                aborted_event
                    .achieve_asynchronously(description: "aborting #{self}") do
                        begin orocos_task.stop(false)
                        rescue StandardError
                        end
                    end
            else
                aborted_event.emit
            end
        end

        on :aborted do |event|
            info "#{event.task} has been aborted"
        end

        # Interrupts the execution of this task context
        event :stop do |_context|
            interrupt!
        end

        on :stop do |_event|
            info "stopped #{self}"
            state_reader.pause if state_reader.respond_to?(:pause)
        end

        # Default implementation of the configure method.
        #
        # This default implementation takes its configuration from
        # State.config.task_name, where +task_name+ is the CORBA task name
        # (i.e. the global name of the task).
        #
        # It then sets the task properties using the values found there
        def configure
            # First, set configuration from the configuration files
            # Note: it can only set properties
            if model.configuration_manager.apply(self, override: true)
                info "applied configuration #{conf} to #{orocos_task.name}"
            end

            # Then set configuration stored in Syskit.conf
            if Syskit.conf.orocos.send("#{orocos_name}?")
                config = Syskit.conf.orocos.send(orocos_name)
                apply_configuration(config)
            end

            # Then set per-device configuration options
            if respond_to?(:each_master_device)
                each_master_device do |device|
                    if device.configuration
                        apply_configuration(device.configuration)
                    elsif device.configuration_block
                        device.configuration_block.call(self)
                    end
                end
            end

            property_overrides.each do |property_override|
                if property_override.has_value?
                    actual_property = properties[property_override.name]
                    if actual_property.has_value?
                        property_override.update_remote_value(actual_property.read)
                    end
                    actual_property.write(property_override.read)
                end
            end

            super if defined? super
        end

        # Clears the currently defined overrides, and restores the original
        # property values
        def clear_property_overrides
            property_overrides.clear_values
            property_overrides.each do |property_override|
                if value = property_override.remote_value
                    properties[property_override.name].write(value)
                end
            end
        end

        # Applies the values stored in +config_type+ to the task properties.
        #
        # It is assumed that config_type responds to each, and that the
        # provided each method yields (name, value) pairs. These pairs are
        # then used to call component.name=value to set the values on the
        # component
        def apply_configuration(config_type)
            config_type.each do |name, value|
                if has_property?(name)
                    property(name).write(value)
                else
                    ::Robot.warn "ignoring field #{name} in configuration "\
                                 "of #{orocos_name} (#{model.name})"
                end
            end
        end

        # Stub this task context by assigning a {Orocos::RubyTaskContext}
        # to {#orocos_task}
        def stub!(name = nil)
            if !name && !orocos_name
                raise ArgumentError,
                      "orocos_task is not set on #{self}, you must "\
                      "provide an explicit name in #stub!"
            end
            self.orocos_name = name if name
            self.orocos_task = Orocos::RubyTaskContext
                               .from_orogen_model(orocos_name, model.orogen_model)
        end

        # Resolves the given Syskit::Port object into the actual Port object
        # on the underlying task.
        #
        # It should not be used directly. One should usually use
        # Port#to_orocos_port instead
        #
        # @return [Orocos::Port]
        def self_port_to_orocos_port(port)
            orocos_port = orocos_task.raw_port(port.name)
            if orocos_port.type != port.type
                raise UnexpectedPortType.new(port, orocos_port.type)
            end

            orocos_port
        end

        # Adds a new port to this model based on a known dynamic port
        #
        # @param [String] name the new port's name
        # @param [Orocos::Spec::DynamicInputPort] port the port model, as
        #   returned for instance by
        #   Orocos::Spec::TaskContext#find_dynamic_input_ports
        # @return [Port] the new port
        def instanciate_dynamic_input_port(name, type, port)
            specialize
            model.instanciate_dynamic_input_port(name, type, port).bind(self)
        end

        # Adds a new port to this model based on a known dynamic port
        #
        # @param [String] name the new port's name
        # @param [Orocos::Spec::DynamicOutputPort] port the port model, as
        #   returned for instance by
        #   Orocos::Spec::TaskContext#find_dynamic_output_ports
        # @return [Port] the new port's model
        def instanciate_dynamic_output_port(name, type, port)
            specialize
            model.instanciate_dynamic_output_port(name, type, port).bind(self)
        end

        module Proxying
            proxy_for TaskContext

            # Create dynamically instantiated ports on the real task
            def commit_transaction
                super if defined? super
                return unless specialized_model?

                Syskit::Models.merge_orogen_task_context_models(
                    __getobj__.model.orogen_model, [model.orogen_model]
                )
            end

            def transaction_modifies_static_ports?
                new_connections_to_static = {}
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if find_input_port(sink_port).static?
                        sources = (new_connections_to_static[sink_port] ||= Set.new)
                        sources << [source_task.orocos_name, source_port]
                    end
                end

                each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                    if find_output_port(source_port).static?
                        sinks = (new_connections_to_static[source_port] ||= Set.new)
                        sinks << [sink_task.orocos_name, sink_port]
                    end
                end

                current_connections_to_static = {}
                ActualDataFlow.each_in_neighbour(orocos_task) do |source_task|
                    # Transactions neither touch ActualDataFlow nor the
                    # task-to-orocos_task mapping. It's safe to check it
                    # straight.
                    connections = ActualDataFlow.edge_info(source_task, orocos_task)
                    connections.each_key do |source_port, sink_port|
                        if ActualDataFlow.static?(orocos_task, sink_port)
                            sources = (current_connections_to_static[sink_port] ||= Set.new)
                            sources << [source_task.name, source_port]
                        end
                    end
                end
                ActualDataFlow.each_out_neighbour(orocos_task) do |sink_task|
                    # Transactions neither touch ActualDataFlow nor the
                    # task-to-orocos_task mapping. It's safe to check it
                    # straight.
                    connections = ActualDataFlow.edge_info(orocos_task, sink_task)
                    connections.each_key do |source_port, sink_port|
                        if ActualDataFlow.static?(orocos_task, source_port)
                            sinks = (current_connections_to_static[source_port] ||= Set.new)
                            sinks << [sink_task.name, sink_port]
                        end
                    end
                end

                current_connections_to_static != new_connections_to_static
            end
        end

        def added_sink(sink, policy)
            super
            relation_graph_for(Flows::DataFlow).modified_tasks << self
        end

        def updated_sink(sink, policy)
            super
            relation_graph_for(Flows::DataFlow).modified_tasks << self
        end

        def removed_sink(source)
            super
            relation_graph_for(Flows::DataFlow).modified_tasks << self
        end

        def has_through_method_missing?(m)
            MetaRuby::DSLs.has_through_method_missing?(
                self, m, "_property" => :has_property?
            ) || super
        end

        def find_through_method_missing(m, args)
            MetaRuby::DSLs.find_through_method_missing(
                self, m, args, "_property" => :find_property
            ) || super
        end
    end
end
