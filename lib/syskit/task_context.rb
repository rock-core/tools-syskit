module Orocos
    module RobyPlugin
        # In the orocos/rtt, a task context is what is usually called a
        # component.
        #
        # Subclasses of TaskContext represent these components in Roby plans,
        # an TaskContext instances may be associated with a Deployment task, that
        # represent the underlying deployment process. The link between a task
        # context and its deployment is usually represented by an executed_by
        # relation.
        class TaskContext < Component
            abstract
            @name = "Orocos::RobyPlugin::TaskContext"

            extend Model

            class << self
                attr_reader :name
                # The Orocos::Generation::TaskContext that represents this
                # deployed task context.
                attr_reader :orogen_spec

                # A state_name => event_name mapping that maps the component's
                # state names to the event names that should be emitted when it
                # enters a new state.
                attr_reader :state_events
                # A name => boolean mapping that says if the task named 'name'
                # is configured
                def configured; @@configured end
            end
            @@configured = Hash.new

            # Returns the event name that maps to the given component state name
            def state_event(name)
                model.state_events[name]
            end

            def initialize(arguments = Hash.new)
                super

                start = event(:start)
                def start.calling(context)
                    super if defined? super

                    if !task.orogen_task
                        if task.execution_agent
                            task.orogen_task = execution_agent.task_handles[task.orocos_name]
                        end
                    end

                    if task.executable?(false) && !task.is_setup?
                        task.setup
                    end
                end
            end

            # Creates a Ruby class which represents the set of properties that
            # the task context has. The returned class will initialize its
            # members to the default values declared in the oroGen files
            def self.config_type_from_properties(register = true)
                if @config_type
                    return @config_type
                end

                default_values = Hash.new
                task_model = self

                config = Class.new do
                    class << self
                        attr_accessor :name
                    end
                    @name = "#{task_model.name}::ConfigType"

                    attr_reader :property_names

                    task_model.orogen_spec.each_property do |p|
		    	singleton_class.class_eval do
			    attr_reader p.name
			end
			instance_variable_set "@#{p.name}", p.type

                        default_values[p.name] =
                            if p.default_value
                                Typelib.from_ruby(p.default_value, p.type)
                            else
                                value = p.type.new
                                value.zero!
                                value
                            end

                        if p.type < Typelib::CompoundType || p.type < Typelib::ArrayType
                            attr_accessor p.name
                        else
                            define_method(p.name) do
                                Typelib.to_ruby(instance_variable_get("@#{p.name}"))
                            end
                            define_method("#{p.name}=") do |value|
                                value = Typelib.from_ruby(value, p.type)
                                instance_variable_set("@#{p.name}", value)
                            end
                        end
                    end

                    define_method(:initialize) do
                        default_values.each do |name, value|
                            instance_variable_set("@#{name}", value.dup)
                        end
                        @property_names = default_values.keys
                    end

                    class_eval <<-EOD
                    def each
                        property_names.each do |name|
                            yield(name, send(name))
                        end
                    end
                    EOD
                end
		if register && !self.constants.include?(:Config)
		    self.const_set(:Config, config)
		end
                @config_type = config
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

            def executable?(with_setup = true) # :nodoc:
	    	if forced_executable?
		    return true
                elsif !@orogen_spec || !@orogen_task
                    return false
                end
                if !super
                    return false
                end
                true
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


            def added_child_object(child, relations, info) # :nodoc:
                super if defined? super
                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    Flows::DataFlow.modified_tasks << self
                end
            end

            def removed_child_object(child, relations) # :nodoc:
                super if defined? super
                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    Flows::DataFlow.modified_tasks << self
                end
            end

            # The PortDynamics object that describes the dynamics of the task
            # itself
            attr_reader :task_dynamics

            # Predicate which returns true if the deployed component is
            # triggered by data on the given port. +port+ is an
            # Orocos::Generation::InputPort instance
            def self.triggered_by?(port)
                if port.respond_to?(:to_str)
                    orogen_spec.event_ports.find { |p| p.name == port.to_str }
                else
                    orogen_spec.event_ports.find { |p| p.name == port.name }
                end

            end

            def minimal_period
                task_dynamics.minimal_period
            end

            # Maximum time between the task gets triggered and the time it is
            # actually triggered
            def trigger_latency
                orogen_spec.expected_trigger_latency
            end

            # Computes the minimal update period from the activity alone. If it
            # is not possible (not enough information, or port-driven task for
            # instance), return nil
            def initial_ports_dynamics
                @task_dynamics = PortDynamics.new

                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                if orogen_spec.activity_type == 'PeriodicActivity'
                    task_dynamics.add_trigger(orogen_spec.period, 1)
                end

                result
            end

            def propagate_ports_dynamics(triggering_connections, result)
                triggering_connections.delete_if do |from_task, from_port, to_port|
                    # The source port is computed, save the period in the input
                    # ports's model
                    if result.has_key?(from_task) && (out_dynamics = result[from_task][from_port])
                        dynamics = (result[self][to_port] ||= PortDynamics.new)
                        dynamics.triggers.concat(out_dynamics.triggers)
                        if model.triggered_by?(to_port)
                            task_dynamics.triggers.concat(out_dynamics.triggers)
                        end
                        true
                    end
                end

                return if !triggering_connections.empty?

                trigger_latency = self.trigger_latency
                if task_dynamics
                    task_minimal_period = self.minimal_period || 0
                    task_sample_count   = task_dynamics.
                        sample_count(task_minimal_period + trigger_latency)
                else
                    task_minimal_period = 0
                    task_sample_count   = 0
                end

                # Propagate explicit update links, i.e. cases where the output
                # port is only updated when a set of input ports is.
                model.each_output do |port|
                    port_model = orogen_spec.context.port(port.name)

                    next if port_model.port_triggers.empty?
                    # Ignore if we don't have the necessary information for the
                    # ports that trigger this one
                    next if port_model.port_triggers.any? { |p| !result[self][p] }

                    dynamics = (result[self][port.name] ||= PortDynamics.new(port.sample_size))

                    # Compute how many samples we will have queued during
                    # +trigger_latency+
                    port_model.port_triggers.map do |trigger_port_name|
                        trigger_port_dynamics = result[self][trigger_port_name]
                        period       = trigger_port_dynamics.minimal_period

                        duration =
                            if model.triggered_by?(trigger_port_name)
                                period + trigger_latency
                            else
                                task_minimal_period + trigger_latency
                            end

                        sample_count = trigger_port_dynamics.
                            sample_count(duration)

                        dynamics.add_trigger(period * port.period,
                                 sample_count)
                    end
                    dynamics.add_trigger(
                        port.burst_period * dynamics.minimal_period,
                        port.burst_size)
                end


                if task_minimal_period != 0
                    model.each_output do |port|
                        port_model = model.port(port.name)
                        next if !port_model.triggered_on_update?

                        dynamics = (result[self][port.name] ||= PortDynamics.new(port.sample_size))
                        dynamics.add_trigger(
                            task_minimal_period * port.period,
                            task_sample_count)
                    end
                end

                true
            end

            def input_port(name)
                if !orogen_task
                    raise ArgumentError, "#input_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
		if port.kind_of?(Orocos::OutputPort)
		    raise ArgumentError, "port #{name} is an output of #{self}"
		end
		port
            end

            def output_port(name)
                if !orogen_task
                    raise ArgumentError, "#output_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
		if port.kind_of?(Orocos::InputPort)
		    raise ArgumentError, "port #{name} is an input of #{self}"
		end
		port
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

            # Called at each cycle to update the orogen_state attribute for this
            # task.
            def update_orogen_state # :nodoc:
                if orogen_spec.context.extended_state_support?
                    @state_reader ||= orogen_task.state_reader(:type => :buffer, :size => 10)
                end

                if @state_reader
                    if v = @state_reader.read_new
                        @last_orogen_state = orogen_state
                        @orogen_state = v
                    end
                else
                    new_state = orogen_task.state
                    if new_state != @orogen_state
                        @last_orogen_state = orogen_state
                        @orogen_state = new_state
                    end
                end

            rescue Orocos::CORBA::ComError => e
                if running?
                    emit :aborted, e
                    @orogen_state = nil
                elsif pending? || starting?
                    event(:start).emit_failed e
                    @orogen_state = nil
                else
                    raise
                end
            end

            # Called to configure the component
            def setup
                if TaskContext.configured[orocos_name]
                    if !is_setup?
                        TaskContext.configured.delete(orocos_name)
                    else
                        raise InternalError, "#{orocos_name} is already configured"
                    end
                end

                if !orogen_task
                    raise InternalError, "#setup called but there is no orogen_task"
                end

                ::Robot.info "setting up #{self}"
                state = read_current_state

                if respond_to?(:configure)
                    configure
                end
                if !Roby.app.orocos_engine.dry_run? && state == :PRE_OPERATIONAL
                    orogen_task.configure
                end
                TaskContext.configured[orocos_name] = true

            rescue Exception => e
                event(:start).emit_failed(e)
            end

            # Returns true if this component needs to be setup by calling the
            # #setup method, or if it can be used as-is
            def check_is_setup
                if !orogen_task
                    return false
                end

                state = read_current_state
                if !state
                    return false
                elsif orogen_task.fatal_error_state?(state)
                    return false
                elsif !Roby.app.orocos_engine.dry_run? && state == :PRE_OPERATIONAL
                    return false
                end

                if respond_to?(:configure)
                    return TaskContext.configured[orocos_name]
                else
                    true
                end
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
                # We're not running yet, so we have to read the state ourselves.
                state = read_current_state

                if state != :STOPPED
                    if orogen_task.exception_state?(orogen_state)
                        orogen_task.reset_exception
                    else
                        raise InternalError, "wrong state in start event: got #{state}, expected STOPPED"
                    end
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

                # Call configure or start, depending on the current state
                ::Robot.info "starting #{to_s}"
                @last_orogen_state = nil
                orogen_task.start
                emit :start
            end

            # Handle a state transition by emitting the relevant events
            def handle_state_changes # :nodoc:
                if orogen_task.exception_state?(orogen_state)
                    @stopping_because_of_error = true
                    @stopping_origin = orogen_state
		    begin
		        orogen_task.reset_exception
		    rescue Orocos::StateTransitionFailed => e
			Robot.warn "cannot reset error on #{name}: #{e.message}"
		    end
                elsif orogen_task.fatal_error_state?(orogen_state)
                    if event = state_event(orogen_state)
                        emit event
                    else emit :fatal_error
                    end

                elsif orogen_state == :RUNNING && last_orogen_state && orogen_task.error_state?(last_orogen_state)
                    emit :running

                elsif orogen_state == :STOPPED || orogen_state == :PRE_OPERATIONAL
                    if @stopping_because_of_error
                        if event = state_event(@stopping_origin)
                            emit event
                        else
                            emit :failed
                        end
                    elsif interrupt?
                        emit :interrupt
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
		        orogen_task.stop
		    end
                rescue Orocos::CORBA::ComError
                    # We actually aborted
		    emit :interrupt
                    emit :aborted
                rescue Orocos::StateTransitionFailed
		    # ALL THE LOGIC BELOW must use the state returned by
		    # read_current_state. Do NOT call other state-related
		    # methods like #state as they will read the state port
                    if (state = read_current_state) && (state != :RUNNING)
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
                @is_setup = false
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
            def self.driver_for(model, arguments = Hash.new)
                if model.respond_to?(:to_str)
                    begin
                        model = data_source_model(model)
                    rescue NameError
                        device_arguments, arguments = Kernel.filter_options arguments,
                            :provides => nil, :interface => nil, :config_type => nil

                        if !device_arguments[:provides] && !device_arguments[:interface]
                            # Look for an existing data source that match the name.
                            # If there is none, we will assume that +self+ describes
                            # the interface of +model+
                            if !system.has_data_service?(model)
                                device_arguments[:interface] = self
                            end
                        end
                        model = system.data_source_type model, device_arguments
                        if !model.config_type
                            model.config_type = config_type_from_properties
                        end
                    end
                end
                if !(model < DataSource)
                    raise ArgumentError, "#{model} is not a device driver model"
                end
                dserv = data_service(model, arguments)
                argument "#{dserv.name}_name"

                model
            end

            # Default implementation of the configure method.
            #
            # This default implementation takes its configuration from
            # State.config.task_name, where +task_name+ is the CORBA task name
            # (i.e. the global name of the task).
            #
            # It then sets the task properties using the values found there
            def configure
                # First, set configuration stored in State.config
                if Roby::State.config.send("#{orogen_name}?")
                    config = Roby::State.config.send(orogen_name)
                    apply_configuration(config)
                end

                # Then set per-source configuration options
                if respond_to?(:each_device_name)
                    each_device_name do |name|
                        device = robot.devices[name]
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

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def self.define_from_orogen(task_spec, system = nil)
                superclass = task_spec.superclass
                if !(supermodel = Roby.app.orocos_tasks[superclass.name])
                    supermodel = define_from_orogen(superclass, system)
                end

                klass = Class.new(supermodel)
                klass.instance_variable_set :@orogen_spec, task_spec
                namespace = Orocos::RobyPlugin.orogen_project_module(task_spec.component.name)
                klass.instance_variable_set :@name, "Orocos::RobyPlugin::#{task_spec.component.name.camelcase(:upper)}::#{task_spec.basename.camelcase(:upper)}"
                klass.instance_variable_set :@system, system
                namespace.const_set(task_spec.basename.camelcase(:upper), klass)
                
                # Define specific events for the extended states (if there is any)
                state_events = { :EXCEPTION => :exception, :FATAL_ERROR => :fatal_error, :RUNTIME_ERROR => :runtime_error }
                task_spec.states.each do |name, type|
                    event_name = name.snakecase.downcase
                    klass.event event_name
                    if type == :fatal
                        klass.forward event_name => :fatal_error
                    elsif type == :exception
                        klass.forward event_name => :exception
                    elsif type == :error
                        klass.forward event_name => :runtime_error
                    end

                    state_events[name.to_sym] = event_name
                end

                klass.instance_variable_set :@state_events, state_events
                klass
            end
        end

        # Placeholders used in the plan to represent a data service that has not
        # been mapped to a task context yet
        class DataServiceProxy < TaskContext
            extend Model
            abstract

            class << self
                attr_accessor :name
            end
            @name = "Orocos::RobyPlugin::DataServiceProxy"

            def self.proxied_data_services
                data_services.values
            end
            def proxied_data_services
                self.model.proxied_data_services
            end
        end
    end
end

