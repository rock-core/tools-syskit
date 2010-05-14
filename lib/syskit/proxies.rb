require 'orocos'
require 'utilrb/module/define_or_reuse'

module Orocos
    module RobyPlugin
        class << self
            attr_reader :process_servers
        end
        @process_servers = Hash.new

        Generation = ::Orocos::Generation
        module Deployments
        end

        # Instances of Project are the namespaces into which the other
        # orocos-related objects (Deployment and TaskContext) are defined.
        #
        # For instance, the TaskContext sublass that represnets an imu::Driver
        # task context will be registered as Orocos::RobyPlugin::Imu::Driver
        class Project < Module
            # The instance of Orocos::Generation::TaskLibrary that contains the
            # specification information for this orogen project.
            attr_reader :orogen_spec
        end

        # Returns the Project instance that represents the given orogen project.
        def self.orogen_project_module(name)
            const_name = name.camelcase(true)
            Orocos::RobyPlugin.define_or_reuse(const_name) do
                mod = Project.new
                mod.instance_variable_set :@orogen_spec, ::Roby.app.loaded_orogen_projects[name]
                mod
            end
        end

        # In oroGen, a deployment is a Unix process that holds a certain number
        # of task contexts. This Roby task represents the unix process itself.
        # Once it gets instanciated, the associated task contexts can be
        # accessed with #task(name)
        class Deployment < ::Roby::Task
            attr_accessor :robot

            class << self
                # The Orocos::Generation::StaticDeployment that represents this
                # deployment.
                attr_reader :orogen_spec

                def all_deployments; @@all_deployments end
            end
            @@all_deployments = Hash.new

            def orogen_spec; self.class.orogen_spec end

            attr_reader :task_handles

            # The underlying Orocos::Process instance
            attr_reader :orogen_deployment

            event :signaled
            forward :signaled => :failed

            # Returns the name of this particular deployment instance
            def self.deployment_name
                orogen_spec.name
            end

            # An array of Orocos::Generation::TaskDeployment instances that
            # represent the tasks available in this deployment. Associated plan
            # objects can be instanciated with #task
            def self.tasks
                orogen_spec.task_activities
            end

            def instanciate_all_tasks
                orogen_spec.task_activities.map do |act|
                    task(act.name)
                end
            end

            # Returns an task instance that represents the given task in this
            # deployment.
            def task(name)
                activity = orogen_spec.task_activities.find { |act| name == act.name }
                if !activity
                    raise ArgumentError, "no task called #{name} in #{self.class.deployment_name}"
                end

                klass = Roby.app.orocos_tasks[activity.context.name]
                task = klass.new
                task.robot = robot
                task.executed_by self
                task.orogen_spec = activity
                if ready?
                    task.orogen_task = task_handles[name]
                end
                task
            end

            ##
            # method: start!
            #
            # Starts the process and emits the start event immediately. The
            # :ready event will be emitted when the deployment is up and
            # running.
            event :start do |context|
                RobyPlugin.info { "starting deployment #{model.deployment_name}" }

                host = self.arguments['on'] || 'localhost'
                @orogen_deployment = Orocos::RobyPlugin.process_servers[host].start(model.deployment_name)
                Deployment.all_deployments[@orogen_deployment] = self
                emit :start
            end

            def dead!(result)
                if !result
                    emit :failed
                elsif result.success?
                    emit :success
                elsif result.signaled?
                    emit :signaled, result
                else
                    emit :failed, result
                end

                Deployment.all_deployments.delete(orogen_deployment)
                orogen_spec.task_activities.each do |act|
                    TaskContext.configured.delete(act.name)
                end
                if task_handles
                    # task_handles is only initialized when ready is reached ...
                    # so can be nil here
                    all_tasks = task_handles.values.to_value_set
                    all_tasks.each do |task|
                        task.each_parent_vertex(ActualDataFlow) do |parent_task|
                            mappings = parent_task[task, ActualDataFlow]
                            mappings.each do |(source_port, sink_port), policy|
                                if policy[:pull] # we have to disconnect explicitely
                                    begin parent_task.port(source_port).disconnect_from(task.port(sink_port, false))
                                    rescue Exception => e
                                        Orocos::RobyPlugin.warn "error while disconnecting #{parent_task}:#{source_port} from #{task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                                    end
                                end
                            end
                        end
                        task.each_child_vertex(ActualDataFlow) do |child_task|
                            mappings = task[child_task, ActualDataFlow]
                            mappings.each do |(source_port, sink_port), policy|
                                begin child_task.port(sink_port).disconnect_all
                                rescue Exception => e
                                    Orocos::RobyPlugin.warn "error while disconnecting #{task}:#{source_port} from #{child_task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                                end
                            end
                        end

                        ActualDataFlow.remove(task)
                        RequiredDataFlow.remove(task)
                    end
                end

                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orogen_task = nil
                end
            end

            # Event emitted when the deployment is up and running
            event :ready

            poll do
                begin
                    next if ready?

                    if orogen_deployment.wait_running(0)
                        Orocos::Process.log_all_ports(orogen_deployment, :log_dir => Roby.app.log_dir)

                        @task_handles = Hash.new
                        orogen_spec.task_activities.each do |activity|
                            task_handles[activity.name] = 
                                ::Orocos::TaskContext.get(activity.name)
                        end

                        each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                            task.orogen_task = task_handles[task.orocos_name]
                        end

                        emit :ready
                    end
                rescue Exception => e
                    STDERR.puts e.message
                    raise
                end
            end

            ##
            # method: stop!
            #
            # Stops all tasks that are running on top of this deployment, and
            # kill the deployment
            event :stop do |context|
                to_be_killed = each_executed_task.find_all(&:running?)
                if to_be_killed.empty?
                    orogen_deployment.kill(false)
                    return
                end

                # Add an intermediate event that will fire when the intermediate
                # tasks have been stopped
                terminal = Roby::AndGenerator.new
                to_be_killed.each do |task|
                    task.stop!
                    terminal << task.stop_event
                end
                terminal.on { |event| orogen_deployment.kill(false) }
                # The stop event will get emitted after the process has been
                # killed. See the polling block.
            end

            # Creates a subclass of Deployment that represents the deployment
            # specified by +deployment_spec+.
            #
            # +deployment_spec+ is an instance of Orogen::Generation::Deployment
            def self.define_from_orogen(deployment_spec)
                klass = Class.new(Deployment)
                klass.instance_variable_set :@orogen_spec, deployment_spec
                Orocos::RobyPlugin::Deployments.const_set(deployment_spec.name.camelcase(true), klass)
                klass
            end
        end

        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update(plan) # :nodoc:
            if Roby.app.orocos_engine.modified?
                Roby.app.orocos_engine.resolve
            end

            all_dead_deployments = ValueSet.new
            for name, server in Orocos::RobyPlugin.process_servers
                if dead_deployments = server.wait_termination(0)
                    dead_deployments.each do |p, exit_status|
                        d = Deployment.all_deployments[p]
                        if !d.stop_event.pending?
                            Orocos::RobyPlugin.warn "#{p.name} unexpectedly died on #{name}"
                        end
                        all_dead_deployments << d
                        d.dead!(exit_status)
                    end
                end
            end

            if !(query = plan.instance_variable_get :@orocos_update_query)
                query = plan.find_tasks(Orocos::RobyPlugin::TaskContext).
                    not_finished.not_failed
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                next if !t.orogen_task
                if !t.is_setup? && Roby.app.orocos_auto_configure?
                    t.setup 
                end

                while t.update_orogen_state
                    if t.running?
                        t.handle_state_changes
                    end
                end
            end

            tasks = Flows::DataFlow.modified_tasks
            tasks.delete_if { |t| !t.plan || all_dead_deployments.include?(t.execution_agent) || t.transaction_proxy? }
            if !tasks.empty?
                main_tasks, proxy_tasks = tasks.partition { |t| t.plan.executable? }
                main_tasks = main_tasks.to_value_set
                if Flows::DataFlow.pending_changes
                    main_tasks.merge(Flows::DataFlow.pending_changes.first)
                end

                Engine.info do
                    Engine.info "computing data flow update from modified tasks"
                    for t in main_tasks
                        Engine.info "  #{t}"
                    end
                    break
                end

                new, removed = Roby.app.orocos_engine.compute_connection_changes(main_tasks)
                if new
                    Engine.info do
                        Engine.info "  new connections:"
                        new.each do |(from_task, to_task), mappings|
                            Engine.info "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                            Engine.info "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                            mappings.each do |(from_port, to_port), policy|
                                Engine.info "      #{from_port}:#{to_port} #{policy}"
                            end
                        end
                        Engine.info "  removed connections:"
                        removed.each do |(from_task, to_task), mappings|
                            Engine.info "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                            Engine.info "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                            mappings.each do |from_port, to_port|
                                Engine.info "      #{from_port}:#{to_port}"
                            end
                        end
                            
                        break
                    end

                    pending_replacement =
                        if Flows::DataFlow.pending_changes
                            Flows::DataFlow.pending_changes[3]
                        end

                    Flows::DataFlow.pending_changes = [main_tasks, new, removed, pending_replacement]
                    Flows::DataFlow.modified_tasks.clear
                    Flows::DataFlow.modified_tasks.merge(proxy_tasks.to_value_set)
                else
                    Engine.info "cannot compute changes, keeping the tasks queued"
                end
            end

            if Flows::DataFlow.pending_changes
                _, new, removed, pending_replacement = Flows::DataFlow.pending_changes
                if pending_replacement && !pending_replacement.happened? && !pending_replacement.unreachable?
                    Engine.info "waiting for replaced tasks to stop"
                else
                    if pending_replacement
                        Engine.info "successfully started replaced tasks, now applying pending changes"
                        pending_replacement.clear_vertex
                        plan.unmark_permanent(pending_replacement)
                    end

                    pending_replacement = catch :cancelled do
                        Engine.info "applying pending changes from the data flow graph"
                        Roby.app.orocos_engine.apply_connection_changes(new, removed)
                        Flows::DataFlow.pending_changes = nil
                    end

                    if !Flows::DataFlow.pending_changes
                        Engine.info "successfully applied pending changes"
                    elsif pending_replacement
                        Engine.info "waiting for replaced tasks to stop"
                        plan.add_permanent(pending_replacement)
                        Flows::DataFlow.pending_changes[3] = pending_replacement
                    else
                        Engine.info "failed to apply pending changes"
                    end
                end
            end
        end

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

            extend Model

            class << self
                attr_reader :name
                # The Orocos::Generation::StaticDeployment that represents this
                # task context.
                attr_reader :orogen_spec
                # A mapping from state name to event name
                attr_reader :state_events
                # A name => boolean mapping that says if the task named 'name'
                # is configured
                def configured; @@configured end
            end
            @@configured = Hash.new

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

            def create_fresh_copy
                new_task = super
                new_task.orogen_task = orogen_task
                new_task.orogen_spec = orogen_spec
                new_task
            end

            def executable?(with_setup = true)
                if !@orogen_spec || !@orogen_task
                    return false
                end
                if !super
                    return false
                end
                true
            end

            def added_child_object(child, relations, info)
                super if defined? super
                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    Flows::DataFlow.modified_tasks << self
                end
            end

            def removed_child_object(child, relations)
                super if defined? super
                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    Flows::DataFlow.modified_tasks << self
                end
            end

            attr_reader :minimal_period

            def self.triggered_by?(port)
                orogen_spec.event_ports.find { |p| p.name == port.name }
            end

            def trigger_latency
                orogen_spec.expected_trigger_latency
            end

            def update_minimal_period(period)
                if !@minimal_period || @minimal_period > period
                    @minimal_period = period
                end
            end

            # Computes the minimal update period from the activity alone. If it
            # is not possible (not enough information, or port-driven task for
            # instance), return nil
            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                if orogen_spec.activity_type == 'PeriodicActivity'
                    update_minimal_period(orogen_spec.period)
                end

                result
            end

            def propagate_ports_dynamics(result)
                handled_inputs = Set.new
                each_concrete_input_connection do |from_task, from_port, to_port, _|
                    next if !orogen_spec.context.event_ports.find { |p| p.name == to_port }
                    if result[self][to_port] && result[self][to_port].period
                        handled_inputs << to_port
                        next
                    end

                    if result.has_key?(from_task) && (dynamics = result[from_task][from_port]) && dynamics.period
                        result[self][to_port] ||= PortDynamics.new
                        result[self][to_port].period = dynamics.period
                        handled_inputs << to_port
                        update_minimal_period(dynamics.period)
                    end
                end

                model.each_output do |port|
                    port_model = orogen_spec.context.port(port.name)

                    next if port_model.triggered_on_update?
                    periods = port_model.port_triggers.map do |trigger_port|
                        result[self][trigger_port.name]
                    end.compact.map(&:period).compact
                    if periods.size == port_model.port_triggers.size
                        result[self][port.name] ||= PortDynamics.new
                        result[self][port.name].period = periods.min * port.period
                    end
                end

                if minimal_period && (handled_inputs.size == orogen_spec.context.event_ports.size)
                    model.each_output do |port|
                        port_model = orogen_spec.context.port(port.name)
                        if port_model.triggered_on_update?
                            result[self][port.name] ||= PortDynamics.new
                            result[self][port.name].period = minimal_period * port.period
                        end
                    end

                    true
                else
                    remaining = orogen_spec.context.each_port.map(&:name).to_set
                    remaining -= result[self].keys.to_set
                    Engine.info { "cannot find period information for " + remaining.to_a.join(", ") }
                    false
                end
            end

            def input_port(name)
                if !orogen_task
                    raise ArgumentError, "#input_port called but we have no task handler yet"
                end
                orogen_task.input_port(name)
            end

            def output_port(name)
                if !orogen_task
                    raise ArgumentError, "#output_port called but we have no task handler yet"
                end
                orogen_task.output_port(name)
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
                    if !orogen_task.port('state').connected?
                        raise InternalError, "the state reader has been disconnected"
                    end
                    if v = @state_reader.read
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
                elsif pending? || starting?
                    event(:start).emit_failed e
                end
            end

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
                if state == :PRE_OPERATIONAL
                    orogen_task.configure
                end
                TaskContext.configured[orocos_name] = true

            rescue Exception => e
                event(:start).emit_failed(e)
            end

            def check_is_setup
                if orogen_spec.context.needs_configuration?
                    if !orogen_task
                        return false
                    else
                        state = read_current_state
                        if !state
                            return false
                        elsif state == :PRE_OPERATIONAL
                            return false
                        end
                    end
                end

                if respond_to?(:configure)
                    return TaskContext.configured[orocos_name]
                else
                    true
                end
            end

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
                    if orogen_task.fatal_error_state?(orogen_state)
                        orogen_task.reset_error
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
                if orogen_task.fatal_error_state?(orogen_state)
                    @stopping_because_of_error = true
                    @stopping_origin = orogen_state
                    orogen_task.reset_error
                elsif orogen_state == :RUNNING && last_orogen_state && orogen_task.error_state?(last_orogen_state)
                    emit :running
                elsif orogen_state == :STOPPED
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
                begin
                    orogen_task.stop
                rescue Orocos::StateTransitionFailed
                    if state = read_current_state && orogen_task.fatal_error_state?(state)
                        # Nothing to do, the poll block will finalize the task
                    else
                        raise
                    end
                end
            end
            forward :interrupt => :failed

            # Emitted when the component recovers from a runtime error state
            event :running

            # Emitted when the component goes into one of the runtime error
            # states
            event :runtime_error

            event :fatal_error
            forward :fatal_error => :failed

            on :aborted do |event|
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
                if @state_reader
                    @state_reader.disconnect
                end
            end

            def self.driver_for(model, arguments = Hash.new)
                if model.respond_to?(:to_str)
                    begin
                        model = Orocos::RobyPlugin::DataSources.const_get model.to_str.camelcase(true)
                    rescue NameError
                        device_arguments, arguments = Kernel.filter_options arguments,
                            :provides => nil

                        if !device_arguments[:provides]
                            # Look for an existing data source that match the name.
                            # If there is none, we will assume that +self+ describes
                            # the interface of +model+
                            if !system.has_data_service?(model)
                                device_arguments[:interface] = self
                            end
                        end
                        model = system.data_source_type model, device_arguments
                    end
                end
                if !(model < DataSource)
                    raise ArgumentError, "#{model} is not a device driver model"
                end
                data_service_name, _ = data_service(model, arguments)
                argument "#{data_service_name}_name"

                model
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
                klass.instance_variable_set :@name, "#{task_spec.component.name.camelcase(true)}::#{task_spec.basename.camelcase(true)}"
                klass.instance_variable_set :@system, system
                namespace.const_set(task_spec.basename.camelcase(true), klass)
                
                # Define specific events for the extended states (if there is any)
                state_events = { :FATAL_ERROR => :fatal_error, :RUNTIME_ERROR => :runtime_error }
                task_spec.states.each do |name, type|
                    event_name = name.snakecase.downcase
                    klass.event event_name
                    if type == :fatal
                        klass.forward event_name => :fatal_error
                    elsif type == :error
                        klass.forward event_name => :runtime_error
                    end

                    state_events[name.to_sym] = event_name
                end

                klass.instance_variable_set :@state_events, state_events
                klass
            end
        end

        RequiredDataFlow = ConnectionGraph.new
        Orocos::RobyPlugin::TaskContext.include BGL::Vertex
    end
end

