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
            Component.submodels << TaskContext

            extend Logger::Hierarchy
            include Logger::Hierarchy

            abstract

            # See Models::Base#permanent_model?
            @permanent_model = true

            # The task's configuration, as a list of registered configurations
            # for the underlying task context
            #
            # For instance ['default', 'left_camera'] will apply the 'default'
            # section of config/orogen/orogen_project::TaskClassName.yml and
            # then override with the 'left_camera' section of the same file
            argument :conf
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
            attr_accessor :orocos_task
            # [Orocos::Generation::TaskDeployment] the model of this deployment
            attr_accessor :orogen_model
            # The current state for the orogen task. It is a symbol that
            # represents the state name (i.e. :RUNTIME_ERROR, :RUNNING, ...)
            attr_reader :orogen_state
            # The last state before we went to orogen_state
            attr_reader :last_orogen_state

            # @!attribute r tid
            #   @return [Integer] The thread ID of the thread running this task
            #   Beware, the thread might be on a remote machine !
            def tid
                orocos_task.tid
            end

            # [Symbol] Returns the task's event name that maps to the given component state name
            def state_event(name)
                model.state_events[name]
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
                    :orogen_model => nil
                super(task_options)

                @orogen_model   = options[:orogen_model] ||
                    Orocos::Spec::TaskDeployment.new(nil, model.orogen_model)

                @allow_automatic_setup = true

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
            D_SAME_MACHINE = 1
            # Value returned by TaskContext#distance_to when the tasks are in
            # different processes localized on different machines
            D_DIFFERENT_MACHINES = 2
            # Maximum distance value
            D_MAX          = 2

            # Returns true if +self+ and +task+ are on the same process server
            def on_same_server?(task)
                distance_to(task) != D_DIFFERENT_MACHINES
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
                elsif execution_agent.machine == other.execution_agent.machine # same machine
                    D_SAME_MACHINE
                else
                    D_DIFFERENT_MACHINES
                end
            end

            # Verifies if a task could be replaced by this one
            #
            # @return [Boolean] true if #merge(other_task) can be called and
            # false otherwise
            def can_merge?(other_task) # :nodoc:
                if !(super_result = super)
                    return super_result
                end

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

            def operation(name)
                orocos_task.operation(name)
            end

            def property(name)
                orocos_task.property(name)
            end

            def read_current_state
                while update_orogen_state
                end
                @orogen_state
            end

            # The size of the buffered connection created between this object
            # and the remote task's state port
            STATE_READER_BUFFER_SIZE = 200

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

            # Create a Orocos::StateReader object to read the state from this
            # task context
            def create_state_reader
                @state_reader = orocos_task.state_reader(:type => :buffer, :size => STATE_READER_BUFFER_SIZE, :init => true, :transport => Orocos::TRANSPORT_CORBA)
            end

            # Called at each cycle to update the orogen_state attribute for this
            # task using the values read from the state reader
            def update_orogen_state
                if orogen_model.context.extended_state_support? && !@state_reader
                    create_state_reader
                end

                if @state_reader
                    if !@state_reader.connected?
                        raise InternalError, "state_reader got disconnected"
                    end

                    if v = @state_reader.read_new
                        @last_orogen_state = orogen_state
                        @orogen_state = v
                    end
                else
                    new_state = orocos_task.rtt_state
                    if new_state != @orogen_state
                        @last_orogen_state = orogen_state
                        @orogen_state = new_state
                    end
                end

            rescue Exception => e
                @orogen_state = nil
            end

            attr_predicate :allow_automatic_setup?, true

            # Returns true if this component needs to be setup by calling the
            # #setup method, or if it can be used as-is
            def ready_for_setup?
                # @allow_automatic_setup is being used to sequence the end of a
                # running task with the reconfiguration of the a new one.
                #
                # It MUST be kept here
                if !@allow_automatic_setup
                    return false
                elsif !orogen_model || !orocos_task
                    return false
                end

                state = begin orocos_task.rtt_state
                        rescue CORBA::ComError
                            return false
                        end

                return (state == :EXCEPTION || state == :STOPPED || state == :PRE_OPERATIONAL)
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
                @setup = true
                if all_inputs_connected?
                    self.executable = nil
                    Runtime.debug { "#{self} is setup and all its inputs are connected, set executable to nil and executable? = #{executable?}" }
                else
                    Runtime.debug { "#{self} is setup but some of its inputs are not connected, keep executable = #{executable?}" }
                end
            end

            # If true, #configure must be called on this task before it is
            # started. This flag is reset after #configure has been called
            def needs_reconfiguration?
                TaskContext.needs_reconfiguration.include?(orocos_name)
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

            # Called to configure the component
            def setup
                if !orocos_task
                    raise InternalError, "#setup called but there is no orocos_task"
                end

                state = orocos_task.rtt_state

                if ![:EXCEPTION, :PRE_OPERATIONAL, :STOPPED].include?(state)
                    raise InternalError, "wrong state in #setup for #{orocos_task}: got #{state}, but only EXCEPTION, PRE_OPERATIONAL and STOPPED are available"
                end

                needs_reconf = false
                if state == :EXCEPTION
                    ::Robot.info "reconfiguring #{self}: the task was in exception state"
                    orocos_task.reset_exception(false)
                    state = orocos_task.rtt_state
                    needs_reconf = true
                elsif state == :PRE_OPERATIONAL
                    needs_reconf = true
                elsif needs_reconfiguration?
                    ::Robot.info "reconfiguring #{self}: the task is marked as needing reconfiguration"
                    needs_reconf = true
                else
                    _, current_conf = TaskContext.configured[orocos_name]
                    if !current_conf
                        needs_reconf = true
                    elsif current_conf != self.conf
                        ::Robot.info "reconfiguring #{self}: configuration changed"
                        needs_reconf = true
                    end
                end

                if !needs_reconf
                    Robot.info "#{self} was already configured"
                    is_setup!
                    return
                end
                if state == :STOPPED && orocos_task.model.needs_configuration?
                    ::Robot.info "cleaning up #{self}"
                    cleaned_up = true
                    orocos_task.cleanup
                end

                ::Robot.info "setting up #{self}"

                self.conf ||= ['default']

                super

                if !Roby.app.orocos_engine.dry_run? && (cleaned_up || state == :PRE_OPERATIONAL)
                    orocos_task.configure(false)
                end
                TaskContext.needs_reconfiguration.delete(orocos_name)
                TaskContext.configured[orocos_name] = [orocos_task.model, self.conf.dup]
            end

            ##
            # :method: start_event
            #
            # Returns the start event object for this task

            ##
            # :method: start!
            #
            # Optionally configures and then start the component. The start
            # event will be emitted when the it has successfully been
            # configured and started.
            event :start do |context|
                # Create the state reader right now. Otherwise, we might not get
                # the state updates related to the task's startup
                if orogen_model.context.extended_state_support?
                    create_state_reader
                end

                # At this point, we should have already created all the dynamic
                # ports that are required ... check that
                each_concrete_output_connection do |source_port, _|
                    if !orocos_task.has_port?(source_port)
                        raise "#{orocos_name}(#{orogen_model.name}) does not have a port named #{source_port}"
                    end
                end
                each_concrete_input_connection do |_, _, sink_port, _|
                    if !orocos_task.has_port?(sink_port)
                        raise "#{orocos_name}(#{orogen_model.name}) does not have a port named #{sink_port}"
                    end
                end

                ::Robot.info "starting #{to_s} (#{orocos_name})"
                @last_orogen_state = nil
                orocos_task.start(false)
                emit :start
            end

            # Handle a state transition by emitting the relevant events
            def handle_state_changes # :nodoc:
                # If we are starting, we should ignore all states until a
                # runtime state is found
                if !@got_running_state
                    if orocos_task.runtime_state?(orogen_state)
                        @got_running_state = true
                        emit :running
                    else
                        return
                    end
                end

                if orocos_task.exception_state?(orogen_state)
                    if event = state_event(orogen_state)
                        emit event
                    else emit :exception
                    end
                elsif orocos_task.fatal_error_state?(orogen_state)
                    if event = state_event(orogen_state)
                        emit event
                    else emit :fatal_error
                    end

                elsif orogen_state == :RUNNING && last_orogen_state && orocos_task.error_state?(last_orogen_state)
                    emit :running

                elsif orogen_state == :STOPPED || orogen_state == :PRE_OPERATIONAL
                    if interrupt?
                        emit :interrupt
                    elsif finishing?
                        emit :stop
                    else
                        emit :success
                    end
                elsif event = state_event(orogen_state)
                    emit event
                end
            end

            ##
            # :method: interrupt!
            #
            # Interrupts the execution of this task context
            event :interrupt do |context|
	        Robot.info "interrupting #{name}"
                begin
		    if !orocos_task # already killed
		        emit :interrupt
		        emit :aborted
		    elsif execution_agent && !execution_agent.finishing?
		        orocos_task.stop(false)
		    end
                rescue Orocos::CORBA::ComError
                    # We actually aborted
		    emit :interrupt
                    emit :aborted
                rescue Orocos::StateTransitionFailed
                    # Use #rtt_state as it has no problem with asynchronous
                    # communication, unlike the port-based state updates.
		    state = orocos_task.rtt_state
                    if state != :RUNNING
			Runtime.debug { "in the interrupt event, StateTransitionFailed: task.state == #{state}" }
                        # Nothing to do, the poll block will finalize the task
                    else
                        raise
                    end
                end
            end

            forward :interrupt => :failed

            ##
            # :method: running_event
            #
            # Returns the running event object for this task. This event gets
            # emitted whenever the component goes into the Running state, either
            # because it has just been started or because it left a runtime
            # error state.
            event :running

            ##
            # :method: runtime_error_event
            #
            # Returns the runtime error event object for this task. This event
            # gets emitted whenever the component goes into a runtime error
            # state.
            event :runtime_error

            ##
            # :method: exception_event
            #
            # Returns the exception error event object for this task. This event
            # gets emitted whenever the component goes into an exception
            # state.
            event :exception
            forward :exception => :failed

            ##
            # :method: fatal_error_event
            #
            # Returns the fatal error event object for this task. This event
            # gets emitted whenever the component goes into a fatal error state.
            #
            # This leads to the component emitting both :failed and :stop
            event :fatal_error
            forward :fatal_error => :failed

            on :aborted do |event|
	        Robot.info "#{event.task} has been aborted"
                @orocos_task = nil
            end

            ##
            # :method: stop!
            #
            # Interrupts the execution of this task context
            event :stop do |context|
                interrupt!
            end

            on :stop do |event|
                ::Robot.info "stopped #{self}"

                # Reset the is_setup flag, as the user might transition to
                # PRE_OPERATIONAL
                if @state_reader
                    @state_reader.disconnect
                end
            end

            # Declares that this task context model can be used as a driver for
            # the device +model+.
            #
            # It will create the corresponding device model if it does not
            # already exist, and return it. See the documentation of
            # Component.data_service for the description of +arguments+
            def self.driver_for(model, arguments = Hash.new, &block)
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
                argument "#{dserv.name}_name"
                dserv
            end

            # Default implementation of the configure method.
            #
            # This default implementation takes its configuration from
            # State.config.task_name, where +task_name+ is the CORBA task name
            # (i.e. the global name of the task).
            #
            # It then sets the task properties using the values found there
            def configure
                super if defined? super

                # First, set configuration from the configuration files
                # Note: it can only set properties
                conf = self.conf || ['default']
                if Orocos.conf.apply(orocos_task, conf, true)
                    Robot.info "applied configuration #{conf} to #{orocos_task.name}"
                end

                # Then set configuration stored in Syskit.conf
                if Syskit.conf.send("#{orogen_name}?")
                    config = Syskit.conf.send(orogen_name)
                    apply_configuration(config)
                end

                # Then set per-device configuration options
                if respond_to?(:each_master_device)
                    each_master_device do |_, device|
                        if device.configuration
                            apply_configuration(device.configuration)
                        elsif device.configuration_block
                            device.configuration_block.call(orocos_task)
                        end
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
                    if orocos_task.has_property?(name)
                        orocos_task.send("#{name}=", value)
                    else
                        Robot.warn "ignoring field #{name} in configuration of #{orocos_name} (#{model.name})"
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
                @orocos_task = Orocos::RubyTaskContext.from_orogen_model(orocos_name, model.orogen_model)
            end
        end
end

