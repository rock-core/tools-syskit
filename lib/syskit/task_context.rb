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
            @name = "Syskit::TaskContext"

            abstract

            argument :conf
            argument :orocos_name

            class << self
                # A name => [orogen_model, current_conf] mapping that says if
                # the task named 'name' is configured
                #
                # orogen_model is the model for +name+ and +current_conf+ an
                # array of configuration sections as expected by #conf. It
                # represents the last configuration applied on +name+
                def configured; @@configured end

                # A set of names that says if the task named 'name' should be
                # reconfigured the next time
                def needs_reconfiguration; @@needs_reconfiguration end
            end
            @@configured = Hash.new
            @@needs_reconfiguration = Set.new

            # Returns the thread ID of the thread running this task
            #
            # Beware, the thread might be on a remote machine !
            def tid
                orogen_task.tid
            end

            # Returns the event name that maps to the given component state name
            def state_event(name)
                model.state_events[name]
            end

            def merge(merged_task)
                super
                self.required_host ||= merged_task.required_host

                if merged_task.orogen_spec && !orogen_spec
                    self.orogen_spec = merged_task.orogen_spec
                end

                if merged_task.orogen_task && !orogen_task
                    self.orogen_task = merged_task.orogen_task
                end
                nil
            end

            def initialize(arguments = Hash.new)
                super

                @allow_automatic_setup = true

                # All tasks start with executable? and setup? set to false
                #
                # Then, the engine will call setup, which will do what it should
                @setup = false
                @required_host = nil
                self.executable = false
            end

            # Returns the task name inside the deployment
            #
            # When using CORBA, this is the CORBA name as well
            def orogen_name
                orogen_spec.name
            end

            def create_fresh_copy # :nodoc:
                new_task = super
                new_task.orogen_task = orogen_task
                new_task.orogen_spec = orogen_spec
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

            # Reimplemented from Component
            #
            # It verifies that the host constraint (i.e. on which host should
            # this task be started) matches
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
                    NetworkMergeSolver.debug { "cannot merge #{other_task} in #{self}: different host constraints" }
                    false
                else
                    true
                end
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

            # Maximum time between the task is sent a trigger signal and the
            # time it is actually triggered
            def trigger_latency
                orogen_spec.worstcase_trigger_latency
            end

            def find_input_port(name)
                if !orogen_task
                    raise ArgumentError, "#find_input_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
		return if !port.respond_to?(:writer)
		port

            rescue Orocos::NotFound
            end

            def input_port(name)
                if !(port = find_input_port(name))
		    raise Orocos::NotFound, "port #{name} is not an input port in #{self}"
		end
		port
            end

            def find_output_port(name)
                if !orogen_task
                    raise ArgumentError, "#find_output_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
                return if !port.respond_to?(:reader)
                port

            rescue Orocos::NotFound
            end

            def output_port(name)
                if !(port = find_output_port(name))
		    raise Orocos::NotFound, "port #{name} is not an output port in #{self}"
		end
		port
            end

            def input_port_model(name)
                if !(p = orogen_task.input_port_model(name))
                    raise Orocos::NotFound, "there is no port #{name} on #{self}"
                end
                p
            end

            def output_port_model(name)
                if !(p = orogen_task.output_port_model(name))
                    raise Orocos::NotFound, "there is no port #{name} on #{self}"
                end
                p
            end

            def each_input_port(&block)
                orogen_task.each_input_port(&block)
            end

            def each_output_port(&block)
                orogen_task.each_output_port(&block)
            end

            def operation(name)
                orogen_task.operation(name)
            end

            def property(name)
                orogen_task.property(name)
            end

            # The Orocos::TaskContext instance that gives us access to the
            # remote task context. Note that it is set only when the task is
            # started.
            attr_accessor :orogen_task
            # The Orocos::Generation::TaskDeployment instance that describes the
            # underlying task
            attr_accessor :orogen_spec
            # The global name of the Orocos task underlying this Roby task
            def orocos_name; orogen_spec.name end
            # The current state for the orogen task. It is a symbol that
            # represents the state name (i.e. :RUNTIME_ERROR, :RUNNING, ...)
            attr_reader :orogen_state
            # The last state before we went to orogen_state
            attr_reader :last_orogen_state

            def read_current_state
                while update_orogen_state
                end
                @orogen_state
            end

            STATE_READER_BUFFER_SIZE = 200

            attr_predicate :validate_orogen_states, true

            def validate_orogen_state_from_rtt_state
                orogen_state = orogen_state
                rtt_state    = orogen_task.rtt_state
                mismatch =
                    case rtt_state
                    when :RUNNING
                        !orogen_task.runtime_state?(orogen_state)
                    when :STOPPED
                        orogen_state != :STOPPED
                    when :RUNTIME_ERROR
                        !orogen_task.error_state?(orogen_state)
                    when :FATAL_ERROR
                        !orogen_task.fatal_error_state?(orogen_state)
                    when :EXCEPTION
                        !orogen_task.exception_state?(orogen_state)
                    end

                if mismatch
                    Engine.warn "state mismatch on #{self} between state=#{orogen_state} and rtt_state=#{rtt_state}"
                    @orogen_state = rtt_state
                    handle_state_changes
                end
            end

            def create_state_reader
                @state_reader = orogen_task.state_reader(:type => :buffer, :size => STATE_READER_BUFFER_SIZE, :init => true, :transport => Orocos::TRANSPORT_CORBA)
            end

            # Called at each cycle to update the orogen_state attribute for this
            # task.
            def update_orogen_state # :nodoc:
                if orogen_spec.context.extended_state_support? && !@state_reader
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
                    new_state = orogen_task.rtt_state
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
                elsif !orogen_spec || !orogen_task
                    return false
                end

                state = begin orogen_task.rtt_state
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
                    Engine.debug { "#{self} is setup and all its inputs are connected, set executable to nil and executable? = #{executable?}" }
                else
                    Engine.debug { "#{self} is setup but some of its inputs are not connected, keep executable = #{executable?}" }
                end
            end

            # If true, #configure must be called on this task before it is
            # started. This flag is reset after #configure has been called
            def needs_reconfiguration?
                if orogen_spec
                    TaskContext.needs_reconfiguration.include?(orocos_name)
                end
            end

            # Make sure that #configure will be called on this task before it
            # gets started
            #
            # See also #setup and #needs_reconfiguration?
            def needs_reconfiguration!
                if orogen_spec
                    TaskContext.needs_reconfiguration << orocos_name
                end
            end

            def reusable?
                super && (!setup? || !needs_reconfiguration?)
            end

            # Called to configure the component
            def setup
                if !orogen_task
                    raise InternalError, "#setup called but there is no orogen_task"
                end

                state = orogen_task.rtt_state

                if ![:EXCEPTION, :PRE_OPERATIONAL, :STOPPED].include?(state)
                    raise InternalError, "wrong state in #setup for #{orogen_task}: got #{state}, but only EXCEPTION, PRE_OPERATIONAL and STOPPED are available"
                end

                needs_reconf = false
                if state == :EXCEPTION
                    ::Robot.info "reconfiguring #{self}: the task was in exception state"
                    orogen_task.reset_exception(false)
                    state = orogen_task.rtt_state
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
                if state == :STOPPED && orogen_task.model.needs_configuration?
                    ::Robot.info "cleaning up #{self}"
                    cleaned_up = true
                    orogen_task.cleanup
                end

                ::Robot.info "setting up #{self}"

                self.conf ||= ['default']

                super

                if !Roby.app.orocos_engine.dry_run? && (cleaned_up || state == :PRE_OPERATIONAL)
                    orogen_task.configure(false)
                end
                TaskContext.needs_reconfiguration.delete(orocos_name)
                TaskContext.configured[orocos_name] = [orogen_task.model, self.conf.dup]
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
                if orogen_spec.context.extended_state_support?
                    create_state_reader
                end

                # At this point, we should have already created all the dynamic
                # ports that are required ... check that
                each_concrete_output_connection do |source_port, _|
                    if !orogen_task.has_port?(source_port)
                        raise "#{orocos_name}(#{orogen_spec.name}) does not have a port named #{source_port}"
                    end
                end
                each_concrete_input_connection do |_, _, sink_port, _|
                    if !orogen_task.has_port?(sink_port)
                        raise "#{orocos_name}(#{orogen_spec.name}) does not have a port named #{sink_port}"
                    end
                end

                ::Robot.info "starting #{to_s} (#{orocos_name})"
                @last_orogen_state = nil
                orogen_task.start(false)
                emit :start
            end

            # Handle a state transition by emitting the relevant events
            def handle_state_changes # :nodoc:
                # If we are starting, we should ignore all states until a
                # runtime state is found
                if !@got_running_state
                    if orogen_task.runtime_state?(orogen_state)
                        @got_running_state = true
                        emit :running
                    else
                        return
                    end
                end

                if orogen_task.exception_state?(orogen_state)
                    if event = state_event(orogen_state)
                        emit event
                    else emit :exception
                    end
                elsif orogen_task.fatal_error_state?(orogen_state)
                    if event = state_event(orogen_state)
                        emit event
                    else emit :fatal_error
                    end

                elsif orogen_state == :RUNNING && last_orogen_state && orogen_task.error_state?(last_orogen_state)
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
		    if !orogen_task # already killed
		        emit :interrupt
		        emit :aborted
		    elsif execution_agent && !execution_agent.finishing?
		        orogen_task.stop(false)
		    end
                rescue Orocos::CORBA::ComError
                    # We actually aborted
		    emit :interrupt
                    emit :aborted
                rescue Orocos::StateTransitionFailed
                    # Use #rtt_state as it has no problem with asynchronous
                    # communication, unlike the port-based state updates.
		    state = orogen_task.rtt_state
                    if state != :RUNNING
			Engine.debug { "in the interrupt event, StateTransitionFailed: task.state == #{state}" }
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
                @orogen_task = nil
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
                    service_options, model_options = Kernel.filter_options arguments, ComponentModel::DATA_SERVICE_ARGUMENTS
                    model = system_model.query_or_create_service_model(
                        model, DeviceModel, model_options, &block)
                else
                    service_options = arguments
                end

                model = Model.validate_service_model(model, system_model, Device)
                if !model.config_type
                    model.config_type = config_type_from_properties
                end
                dserv = provides(model, service_options)
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
                if Orocos.conf.apply(orogen_task, conf, true)
                    Robot.info "applied configuration #{conf} to #{orogen_task.name}"
                end

                # Then set configuration stored in Conf.orocos
                if Roby::Conf.orocos.send("#{orogen_name}?")
                    config = Roby::Conf.orocos.send(orogen_name)
                    apply_configuration(config)
                end

                # Then set per-device configuration options
                if respond_to?(:each_device)
                    each_master_device do |_, device|
                        if device.configuration
                            apply_configuration(device.configuration)
                        elsif device.configuration_block
                            device.configuration_block.call(orogen_task)
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
                    if orogen_task.has_property?(name)
                        orogen_task.send("#{name}=", value)
                    else
                        Robot.warn "ignoring field #{name} in configuration of #{orogen_name} (#{model.orogen_name})"
                    end
                end
            end
        end
end

