module Orocos
    module RobyPlugin
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
            abstract
            @name = "Orocos::RobyPlugin::TaskContext"

            extend Model

            class << self
                attr_accessor :name
                # The Orocos::Generation::TaskContext that represents this
                # deployed task context.
                attr_accessor :orogen_spec

                # A state_name => event_name mapping that maps the component's
                # state names to the event names that should be emitted when it
                # enters a new state.
                attr_accessor :state_events

                # A name => boolean mapping that says if the task named 'name'
                # is configured
                def configured; @@configured end

                def to_s
                    services = each_data_service.map do |name, srv|
                            "#{name}[#{srv.model.short_name}]"
                    end.join(", ")
                    if private_specialization?
                        "#<TaskContext: specialized from #{superclass.name} services: #{services}>"
                    else
                        "#<TaskContext: #{name} services: #{services}>"
                    end
                end

                # :attr: private_specialization?
                #
                # If true, this model is used internally to represent
                # instanciated dynamic services. Otherwise, it is an actual
                # task context model
                attr_predicate :private_specialization?, true

                # Creates a private specialization of the current model
                def specialize(name)
                    if self == TaskContext
                        raise "#specialize should not be used to create a specialization of TaskContext. Use only on \"real\" task context models"
                    end
                    klass = new_submodel
                    klass.private_specialization = true
                    klass.name = name
                    klass.orogen_spec  = RobyPlugin.create_orogen_interface(self.name + "_" + name)
                    klass.state_events = state_events.dup
                    RobyPlugin.merge_orogen_interfaces(klass.orogen_spec, [orogen_spec])
                    klass
                end
            end
            @@configured = Hash.new

            # Returns the event name that maps to the given component state name
            def state_event(name)
                model.state_events[name]
            end

            def merge(merged_task)
                super
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

                self.executable = false
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
                        property_type = p.typelib_type
		    	singleton_class.class_eval do
			    attr_reader p.name
			end
			instance_variable_set "@#{p.name}", property_type

                        default_values[p.name] =
                            if p.default_value
                                Typelib.from_ruby(p.default_value, property_type)
                            else
                                value = property_type.new
                                value.zero!
                                value
                            end

                        if property_type < Typelib::CompoundType || property_type < Typelib::ArrayType
                            attr_accessor p.name
                        else
                            define_method(p.name) do
                                Typelib.to_ruby(instance_variable_get("@#{p.name}"))
                            end
                            define_method("#{p.name}=") do |value|
                                value = Typelib.from_ruby(value, property_type)
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

            # Predicate which returns true if the deployed component is
            # triggered by data on the given port. +port+ is an
            # Orocos::Generation::InputPort instance
            def self.triggered_by?(port)
                if port.respond_to?(:to_str)
                    !!orogen_spec.find_event_port(port.to_str)
                else
                    !!orogen_spec.find_event_port(port.name)
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

            ##
            #:call-seq:
            #   initial_ports_dynamics => { port_name => port_dynamic, ... }
            #
            # Computes the initial port dynamics, i.e. the dynamics that are not
            # due to an external trigger.
            #
            # The information comes from the activity (in case it is a periodic
            # activity) and device models.
            #
            # Returns a mapping from the task's port name to the corresponding
            # instance of PortDynamics, for the ports for which we have some
            # information
            #
            # Also creates and updates the #task_dynamics object
            def initial_ports_dynamics
                @task_dynamics = PortDynamics.new("#{orocos_name}.main")

                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                if orogen_spec.activity_type == 'PeriodicActivity'
                    Engine.debug { "  adding periodic trigger #{orogen_spec.period} 1" }
                    task_dynamics.add_trigger("main-period", orogen_spec.period, 1)
                end

                result
            end

            ##
            # Propagate information from the input ports to the output ports,
            # using the output ports of +self+
            #
            # It will only do partial updates, i.e. will just propagate the
            # ports for which enough information is available
            def propagate_ports_dynamics_on_outputs(result, handled, with_task_dynamics)
                if with_task_dynamics
                    task_minimal_period = task_dynamics.minimal_period
                end

                old_handled_size = handled.size

                # Propagate explicit update links, i.e. cases where the output
                # port is only updated when a set of input ports is.
                model.each_output_port do |port_model|
                    next if handled.include?(port_model.name)
                    next if port_model.port_triggers.empty?
                    next if !with_task_dynamics && port_model.triggered_on_update?

                    # Ignore if we don't have the necessary information for the
                    # ports that trigger this one
                    info_available = port_model.port_triggers.all? do |p|
                        result[p.name] &&
                            (with_task_dynamics || model.triggered_by?(p.name))
                    end
                    next if !info_available

                    handled << port_model.name
                    dynamics =
                        (result[port_model.name] ||=
                         PortDynamics.new("#{orocos_name}.#{port_model.name}",
                                          port_model.sample_size))

                    # Compute how many samples we will have queued during
                    # +trigger_latency+
                    port_model.port_triggers.each do |trigger_port|
                        trigger_port_name = trigger_port.name
                        trigger_port_dynamics = result[trigger_port_name]
                        period       = trigger_port_dynamics.minimal_period

                        sample_count =
                            if model.triggered_by?(trigger_port_name)
                                # The task gets triggered by the input port. It
                                # means that we will get 1 + (number of possible
                                # input samples during trigger_latency) samples
                                # out
                                1 + trigger_port_dynamics.
                                    sample_count(trigger_latency)
                            else
                                trigger_port_dynamics.
                                    sample_count(task_minimal_period + trigger_latency)
                            end

                        dynamics.add_trigger(trigger_port_name, period * port_model.period, 1)
                        dynamics.add_trigger(trigger_port_name, 0, sample_count - 1)
                    end
                    dynamics.add_trigger("burst",
                        port_model.burst_period * dynamics.minimal_period,
                        port_model.burst_size)
                end
                old_handled_size != handled.size
            end

            def propagate_ports_dynamics(triggering_connections, result)
                triggering_connections.delete_if do |from_task, from_port, to_port|
                    if result.has_key?(from_task)
                        out_dynamics = result[from_task][from_port]
                    end
                    next if !out_dynamics

                    # The source port is computed, save the period in the input
                    # ports's model
                    if model.triggered_by?(to_port)
                        task_dynamics.merge(out_dynamics)
                    end

                    # We may need it to propagate triggers to output ports for
                    # which triggering inputs are specified
                    dynamics = (result[self][to_port] ||= PortDynamics.new("#{self.orocos_name}.#{to_port}"))
                    dynamics.merge(out_dynamics)

                    # Handled fine
                    true
                end

                # We don't have all the info we need yet
                if !triggering_connections.empty?
                    return
                end

                model.each_output_port do |port_model|
                    next if !port_model.triggered_on_update?

                    dynamics =
                        (result[self][port_model.name] ||=
                         PortDynamics.new("#{self.orocos_name}.#{port_model.name}", port_model.sample_size))

                    triggered_once = port_model.triggered_once_per_update?
                    task_dynamics.triggers.each do |tr|
                        dynamics.add_trigger("main", tr.period * port_model.period, 1)
                        if !triggered_once
                            dynamics.add_trigger("main", 0, tr.sample_count - 1)
                        end
                    end
                end

                true
            end

            def find_input_port(name)
                if !orogen_task
                    raise ArgumentError, "#find_input_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
		return if port.kind_of?(Orocos::OutputPort)
		port

            rescue Orocos::NotFound
            end

            def input_port(name)
                if !(port = find_output_port(name))
		    raise ArgumentError, "port #{name} is not an input port in #{self}"
		end
		port
            end

            def find_output_port(name)
                if !orogen_task
                    raise ArgumentError, "#find_output_port called but we have no task handler yet"
                end
                port = orogen_task.port(name)
                return if port.kind_of?(Orocos::InputPort)
                port

            rescue Orocos::NotFound
            end

            def output_port(name)
                if !(port = find_output_port(name))
		    raise ArgumentError, "port #{name} is not an output port in #{self}"
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

            rescue Exception => e
                @orogen_state = nil
            end

            # Returns true if this component needs to be setup by calling the
            # #setup method, or if it can be used as-is
            def ready_for_setup?
                if !orogen_spec || !orogen_task
                    return false
                end

                state = begin read_current_state
                        rescue CORBA::ComError
                            return false
                        end

                if !state
                    return false
                elsif orogen_task.fatal_error_state?(state)
                    return false
                end
                true
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
                @setup ||= TaskContext.configured[orocos_name]
            end

            # Called to configure the component
            def setup
                super

                if !orogen_task
                    raise InternalError, "#setup called but there is no orogen_task"
                end

                ::Robot.info "setting up #{self}"
                state = read_current_state

                if TaskContext.configured[orocos_name]
                    if state == :PRE_OPERATIONAL
                        TaskContext.configured.delete(orocos_name)
                    else
                        @setup = true
                        self.executable = nil
                        return
                    end
                end

                if respond_to?(:configure)
                    configure
                end

                if !Roby.app.orocos_engine.dry_run? && state == :PRE_OPERATIONAL
                    orogen_task.configure
                end

                TaskContext.configured[orocos_name] = true
                @setup = true
                self.executable = nil
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
                    service_options, model_options = Kernel.filter_options arguments, Component::DATA_SERVICE_ARGUMENTS
                    model = system_model.query_or_create_service_model(
                        model, DataSourceModel, model_options)
                else
                    service_options = arguments
                end

                model = Model.validate_service_model(model, system_model, DataSource)
                if !model.config_type
                    model.config_type = config_type_from_properties
                end
                dserv = data_service(model, service_options)
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
                # First, set configuration stored in State.config
                if Roby::State.config.send("#{orogen_name}?")
                    config = Roby::State.config.send(orogen_name)
                    apply_configuration(config)
                end

                # Then set per-source configuration options
                if respond_to?(:each_device)
                    each_device do |_, device|
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
            def self.define_from_orogen(task_spec, system_model)
                superclass = task_spec.superclass
                if !(supermodel = Roby.app.orocos_tasks[superclass.name])
                    supermodel = define_from_orogen(superclass, system)
                end
                klass = system_model.
                    task_context(task_spec.name, :child_of => supermodel)

                klass.instance_variable_set :@orogen_spec, task_spec
                
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

            def self.require_dynamic_service(service_model, options)
                # Unlike #data_service, we need to add the service's interface
                # to our own
                RobyPlugin.merge_orogen_interfaces(orogen_spec, [service_model.orogen_spec])

                # Then we can add the service
                data_service(service_model, options)
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
                data_services.values.map(&:model)
            end
            def proxied_data_services
                self.model.proxied_data_services
            end
        end
    end
end

