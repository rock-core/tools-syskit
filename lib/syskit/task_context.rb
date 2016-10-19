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

            abstract

            # The task's configuration, as a list of registered configurations
            # for the underlying task context
            #
            # For instance ['default', 'left_camera'] will apply the 'default'
            # section of config/orogen/orogen_project::TaskClassName.yml and
            # then override with the 'left_camera' section of the same file
            argument :conf, :default => ['default']
            # The name of the remote task context, i.e. the name under which it
            # can be resolved by Orocos.name_service
            argument :orocos_name

            class << self
                # A name => [orogen_deployed_task_context, current_conf] mapping that says if
                # the task named 'name' is configured
                #
                # orogen_deployed_task_context is the model for +name+ and +current_conf+ an
                # array of configuration sections as expected by #conf. It
                # represents the last configuration applied on +name+
                def configured; @@configured end

                # A set of names that says if the task named 'name' should be
                # reconfigured the next time
                def needs_reconfiguration; @@needs_reconfiguration end
            end
            @@configured = Hash.new
            @@needs_reconfiguration = Set.new

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

                remote_handles.default_properties.each do |p_name, p_value|
                    syskit_p = property(p_name)
                    syskit_p.update_remote_value(p_value)
                    if !syskit_p.has_value?
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

            # The PortDynamics object that describes the dynamics of the task
            # itself.
            #
            # The sample_size attribute on this object is ignored. Only the
            # triggers are of any use
            attr_reader :task_dynamics

            # Returns the minimal period, i.e. the minimum amount of time
            # between two triggers
            def minimal_period
                task_dynamics.minimal_period
            end

            # The computed port dynamics for this task
            attribute(:port_dynamics) { Hash.new }

            # Controls whether the task can be removed from the plan
            #
            # Task context objects are kept while they're being set up, for the
            # sake of not breaking the setup process in an uncontrollable way.
            def can_finalize?
                !setting_up?
            end

            # Tries to update the port dynamics information for the input port
            # +port_name+ based on its inputs
            #
            # Returns the new PortDynamics object if successful, and nil
            # otherwise
            def update_input_port_dynamics(port_name)
                dynamics = []
                each_concrete_input_connection(port_name) do |source_task, source_port, sink_port|
                    if dyn = source_task.port_dynamics[source_port]
                        dynamics << dyn
                    else
                        return
                    end
                end
                dyn = PortDynamics.new("#{name}.#{port_name}")
                dynamics.each { |d| dyn.merge(d) }
                port_dynamics[port_name] = dyn
            end

            # Maximum time between the task is sent a trigger signal and the
            # time it is actually triggered
            def trigger_latency
                orogen_model.worstcase_trigger_latency
            end

            def initialize(arguments = Hash.new)
                options, task_options = Kernel.filter_options arguments,
                    orogen_model: nil
                super(task_options)

                self.logger = ::Robot.logger

                @orogen_model   = options[:orogen_model] ||
                    Orocos::Spec::TaskDeployment.new(nil, model.orogen_model)

                @properties = Hash.new
                self.model.orogen_model.each_property do |p|
                    properties[p.name] = Property.new(self, p.name, p.type)
                end

                # All tasks start with executable? and setup? set to false
                #
                # Then, the engine will call setup, which will do what it should
                @setup = false
                @required_host = nil
                self.executable = false
            end

            def create_fresh_copy # :nodoc:
                new_task = super
                new_task.orocos_task  = orocos_task
                new_task.orogen_model = orogen_model
                new_task
            end

            # Value returned by TaskContext#distance_to when the tasks are in
            # the same process
            D_SAME_PROCESS = 0
            # Value returned by TaskContext#distance_to when the tasks are in
            # different processes, but on the same machine
            D_SAME_HOST = 1
            # Value returned by TaskContext#distance_to when the tasks are in
            # different processes localized on different machines
            D_DIFFERENT_HOSTS = 2
            # Maximum distance value
            D_MAX          = 2

            # Returns true if +self+ and +task+ are on the same process server
            def on_same_server?(task)
                d = distance_to(task)
                d && d != D_DIFFERENT_HOSTS
            end

            # Returns a value that represents how the two task contexts are far
            # from each other. The possible return values are:
            #
            # nil::
            #   one or both of the tasks are not deployed
            # D_SAME_PROCESS::
            #   both tasks are in the same process
            # D_SAME_MACHINE::
            #   both tasks are in different processes, but on the same machine
            # D_DIFFERENT_MACHINES::
            #   both tasks are in different processes localized on different
            #   machines
            def distance_to(other)
                return if !execution_agent || !other.execution_agent

                if execution_agent == other.execution_agent # same process
                    D_SAME_PROCESS
                elsif execution_agent.host == other.execution_agent.host # same machine
                    D_SAME_HOST
                else
                    D_DIFFERENT_HOSTS
                end
            end

            # Verifies if a task could be replaced by this one
            #
            # @return [Boolean] true if #merge(other_task) can be called and
            # false otherwise
            def can_merge?(other_task) # :nodoc:
                return if !super

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
                if !super
                    return false
                elsif !task.setup?
                    return true
                end

                # NOTE: in the two tests below, we use the fact that
                # {#can_merge?} (and therefore {Component#can_be_deployed_by?})
                # already checked that services that have the same name in task
                # and self are actually of identical definition.
                task.each_required_dynamic_service do |srv|
                    if srv.model.remove_when_unused? && !find_data_service(srv.name)
                        return false
                    end
                end
                each_required_dynamic_service do |srv|
                    if !srv.model.dynamic? && !task.find_data_service(srv.name)
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
                return hints if !hints.empty?

                if respond_to?(:each_master_device)
                    each_master_device do |dev|
                        hints |= dev.requirements.deployment_hints.to_set
                    end
                end
                return hints if !hints.empty?

                super
            end

            def operation(name)
                orocos_task.operation(name)
            end

            attr_reader :properties

            # Enumerate this task's known properties
            def each_property(&block)
                properties.each_value(&block)
            end

            # Whether this task has a property with the given name
            def has_property?(name)
                properties.has_key?(name)
            end

            # Returns the syskit-side representation of the given property
            #
            # Properties in Syskit are applied only at configuration time, or
            # when #commit_properties is called
            def property(name)
                if p = properties[name]
                    p
                else
                    raise Orocos::InterfaceObjectNotFound.new(self, name), "#{self} has no property called #{name}"
                end
            end

            # Event emitted when a property commit has successfully finished
            event :properties_updated

            # Apply the values set for the properties to the underlying node
            def commit_properties(promise = self.promise(description: "#{self}#commit_properties"))
                promise = promise.on_success do
                    each_property.map do |p|
                        if p.has_value?
                            [p, p.value.dup]
                        end
                    end.compact
                end.then(description: "write remote properties") do |properties|
                    properties.map do |p, p_value|
                        begin
                            remote = (p.remote_property ||= orocos_task.raw_property(p.name))
                            remote.write(p_value)
                            [Time.now, p, nil]
                        rescue ::Exception => e
                            [Time.now, p, e]
                        end
                    end.compact
                end.on_success(description: "update local data structures") do |result|
                    result.each do |timestamp, property, error|
                        if error
                            execution_engine.add_error(PropertyUpdateError.new(error, property))
                        else
                            property.update_remote_value(property.value)
                            property.update_log(timestamp)
                        end
                    end
                end

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
                if !state_reader.connected?
                    fatal "terminating #{self}, its state reader #{state_reader} is disconnected"
                    aborted!
                    return
                end

                if v = state_reader.read_new
                    @last_orogen_state = orogen_state
                    @orogen_state = v
                end
            end

            # The set of state names from which #configure can be called
            RTT_CONFIGURABLE_STATES = [:EXCEPTION, :STOPPED, :PRE_OPERATIONAL]

            # @api private
            #
            # Pull all state changes that are still queued within the state
            # reader and returns the last one
            #
            # It is destructive, as it does "forget" any pending state changes
            # currently queued.
            def read_current_state
                while new_state = state_reader.read_new
                    state = new_state
                end
                state || state_reader.read
            end

            # Returns true if this component needs to be setup by calling the
            # #setup method, or if it can be used as-is
            def ready_for_setup?(state = nil)
                if !super()
                    return false
                elsif !all_inputs_connected?(only_static: true)
                    return false
                elsif !orogen_model || !orocos_task
                    return false
                end

                state ||= read_current_state
                return RTT_CONFIGURABLE_STATES.include?(state)
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

            # Announces that the task is indeed setup
            #
            # This is meant for internal use. Don't use it unless you know what
            # you are doing
            def is_setup!
                if all_inputs_connected?
                    self.executable = nil
                    execution_engine.scheduler.report_action "configured and all inputs connected, marking as executable", self
                    Runtime.debug { "#{self} is setup and all its inputs are connected, set executable to nil and executable? = #{executable?}" }
                else
                    execution_engine.scheduler.report_action "configured, but some connections are pending", self
                    Runtime.debug { "#{self} is setup but some of its inputs are not connected, keep executable = #{executable?}" }
                end
                super
            end

            # If true, #configure must be called on this task before it is
            # started. This flag is reset after #configure has been called
            def needs_reconfiguration?
                TaskContext.needs_reconfiguration?(orocos_name)
            end

            def self.needs_reconfiguration?(orocos_name)
                needs_reconfiguration.include?(orocos_name)
            end

            # Make sure that #configure will be called on this task before it
            # gets started
            #
            # See also #setup and #needs_reconfiguration?
            def needs_reconfiguration!
                TaskContext.needs_reconfiguration << orocos_name
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
                to_remove = Hash.new
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
                to_remove = Hash.new
                real_model = self.model.concrete_model
                dynamic_ports = self.model.each_input_port.find_all do |p|
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
                to_remove = Hash.new
                real_model = self.model.concrete_model
                dynamic_ports = self.model.each_output_port.find_all do |p|
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

            def preparing_for_setup?
                @preparing_for_setup && !@preparing_for_setup.complete?
            end

            def prepare_for_setup(promise)
                promise.
                    then do
                        properties = Array.new
                        orocos_task.property_names.each do |p_name|
                            p = orocos_task.property(p_name)
                            properties << [p, p.raw_read]
                        end
                        [properties, orocos_task.port_names, orocos_task.rtt_state]
                    end.on_success do |properties, port_names, state|
                        properties.each do |p, p_value|
                            syskit_p = property(p.name)
                            syskit_p.update_remote_value(p_value)
                            syskit_p.update_log_metadata(p.log_metadata)
                        end

                        needs_reconfiguration = true
                        if !ready_for_setup?(state)
                            raise InternalError, "#setup called on #{self} but we are not ready for setup"
                        elsif !needs_reconfiguration?
                            _, current_conf, dynamic_services = TaskContext.configured[orocos_name]
                            if current_conf
                                if current_conf == self.conf && dynamic_services == each_required_dynamic_service.to_set
                                    info "not reconfiguring #{self}: the task is already configured as required"
                                    needs_reconfiguration = false
                                end
                            end
                        end
                        [needs_reconfiguration, port_names, state]
                    end.
                    then do |needs_reconfiguration, port_names, state|
                        if state == :EXCEPTION
                            info "reconfiguring #{self}: the task was in exception state"
                            orocos_task.reset_exception(false)
                            [true, port_names]
                        elsif needs_reconfiguration && (state != :PRE_OPERATIONAL)
                            info "cleaning up #{self}"
                            orocos_task.cleanup(false)
                            [true, port_names]
                        else
                            [false, port_names]
                        end
                    end.
                    on_success do |cleaned_up, port_names|
                        if cleaned_up
                            clean_dynamic_port_connections(port_names)
                        end
                    end
            end

            # Called to configure the component
            def setup(promise)
                if setup?
                    raise ArgumentError, "#{self} is already set up"
                end

                promise = prepare_for_setup(promise)
                # This calls #configure
                promise = super(promise)

                promise = promise.on_success do
                    if self.model.needs_stub?(self)
                        self.model.prepare_stub(self)
                    end
                    if Syskit.conf.logs.conf_logs_enabled?
                        each_property do |p|
                            p.log_stream = Syskit.conf.logs.log_stream_for(p)
                            p.update_log
                        end
                    end
                end
                promise = commit_properties(promise)
                promise.then do
                    state = orocos_task.rtt_state
                    if state == :PRE_OPERATIONAL
                        info "setting up #{self}"
                        orocos_task.configure(false)
                    else
                        info "#{self} was already configured"
                    end
                end.on_success do
                    TaskContext.needs_reconfiguration.delete(orocos_name)
                    TaskContext.configured[orocos_name] = [
                        model,
                        self.conf.dup,
                        self.each_required_dynamic_service.to_set]
                end
            end

            # Returns the start event object for this task

            # Optionally configures and then start the component. The start
            # event will be emitted when the it has successfully been
            # configured and started.
            event :start do |context|
                info "starting #{to_s}"
                @last_orogen_state = nil

                expected_output_ports = each_concrete_output_connection.
                    map { |port_name, _| port_name }
                expected_input_ports = each_concrete_input_connection.
                    map { |_, _, port_name, _| port_name }
                promise = execution_engine.promise(description: "#{self}#start") do
                    port_names = orocos_task.port_names.to_set
                    # At this point, we should have already created all the dynamic
                    # ports that are required ... check that
                    expected_output_ports.each do |source_port|
                        if !port_names.include?(source_port)
                            raise Orocos::NotFound, "#{orocos_name}(#{orogen_model.name}) does not have a port named #{source_port}"
                        end
                    end
                    expected_input_ports.each do |sink_port|
                        if !port_names.include?(sink_port)
                            raise Orocos::NotFound, "#{orocos_name}(#{orogen_model.name}) does not have a port named #{sink_port}"
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
                if !@got_running_state
                    if orocos_task.runtime_state?(orogen_state)
                        @got_running_state = true
                        start_event.emit
                    else
                        return
                    end
                end

                if orocos_task.runtime_state?(orogen_state)
                    if last_orogen_state && orocos_task.error_state?(last_orogen_state)
                        running_event.emit
                    end
                end

                if orogen_state == :STOPPED || orogen_state == :PRE_OPERATIONAL
                    if interrupt_event.pending?
                        interrupt_event.emit
                    elsif finishing?
                        stop_event.emit
                    else
                        success_event.emit
                    end
                elsif orogen_state != :RUNNING
                    if event_name = state_event(orogen_state)
                        event(event_name).emit
                    else
                        raise ArgumentError, "#{self} reports state #{orogen_state}, but I don't have an event for this state transition"
                    end
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
                if state != :RUNNING
                    Runtime.debug { "in the interrupt event, StateTransitionFailed: task.state == #{state}" }
                    # Nothing to do, the poll block will finalize the task
                    nil
                else
                    raise
                end
            end

            # Interrupts the execution of this task context
            event :interrupt do |context|
	        info "interrupting #{name}"

                if !orocos_task # already killed
                    interrupt_event.emit
                    aborted_event.emit
                elsif execution_agent && !execution_agent.finishing?
                    promise = execution_engine.promise(description: "#{self}#stop") { stop_orocos_task }.
                        on_success do |result|
                            if result == :aborted
                                interrupt_event.emit
                                aborted_event.emit
                            end
                        end

                    interrupt_event.achieve_asynchronously(promise, emit_on_success: false)
                end
            end

            forward :interrupt => :failed

            # Returns the running event object for this task. This event gets
            # emitted whenever the component goes into the Running state, either
            # because it has just been started or because it left a runtime
            # error state.
            event :running
            forward :start => :running

            # Returns the runtime error event object for this task. This event
            # gets emitted whenever the component goes into a runtime error
            # state.
            event :runtime_error

            # Returns the exception error event object for this task. This event
            # gets emitted whenever the component goes into an exception
            # state.
            event :exception
            forward :exception => :failed

            # Returns the fatal error event object for this task. This event
            # gets emitted whenever the component goes into a fatal error state.
            #
            # This leads to the component emitting both :failed and :stop
            event :fatal_error
            forward :fatal_error => :failed

            event :aborted, terminal: true do |context|
                if execution_agent && execution_agent.running? && !execution_agent.finishing?
                    aborted_event.achieve_asynchronously(description: "aborting #{self}") do
                        begin orocos_task.stop(false)
                        rescue Exception
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
            event :stop do |context|
                interrupt!
            end

            on :stop do |event|
                info "stopped #{self}"
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

                super if defined? super
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
                        ::Robot.warn "ignoring field #{name} in configuration of #{orocos_name} (#{model.name})"
                    end
                end
            end

            # Stub this task context by assigning a {Orocos::RubyTaskContext} to {#orocos_task}
            def stub!(name = nil)
                if !name && !orocos_name
                    raise ArgumentError, "orocos_task is not set on #{self}, you must provide an explicit name in #stub!"
                end
                if name
                    self.orocos_name = name
                end
                self.orocos_task = Orocos::RubyTaskContext.from_orogen_model(orocos_name, model.orogen_model)
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
            #   returned for instance by Orocos::Spec::TaskContext#find_dynamic_input_ports
            # @return [Port] the new port
            def instanciate_dynamic_input_port(name, type, port)
                specialize
                model.instanciate_dynamic_input_port(name, type, port).bind(self)
            end

            # Adds a new port to this model based on a known dynamic port
            # 
            # @param [String] name the new port's name
            # @param [Orocos::Spec::DynamicOutputPort] port the port model, as
            #   returned for instance by Orocos::Spec::TaskContext#find_dynamic_output_ports
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
                    if specialized_model?
                        Syskit::Models.merge_orogen_task_context_models(__getobj__.model.orogen_model, [model.orogen_model])
                    end
                end

                def transaction_modifies_static_ports?
                    new_connections_to_static = Hash.new
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

                    current_connections_to_static = Hash.new
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
        end
end

