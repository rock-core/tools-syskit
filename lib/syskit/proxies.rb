require 'orocos'
require 'utilrb/module/define_or_reuse'

module Orocos
    module RobyPlugin
        class << self
            # The set of known process servers.
            #
            # It maps the server name to the Orocos::ProcessServer instance
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

            def initialize(arguments = Hash.new)
	    	opts, task_arguments = Kernel.filter_options  arguments, :log => true
		task_arguments[:log] = opts[:log]
                super(task_arguments)
	    end

            class << self
                # The Orocos::Generation::StaticDeployment that represents this
                # deployment.
                attr_reader :orogen_spec

                def all_deployments; @@all_deployments end
            end
            @@all_deployments = Hash.new

            # Returns the name of this particular deployment instance
            def self.deployment_name
                orogen_spec.name
            end

            # The Orocos::Generation::StaticDeployment object describing this
            # deployment. This is a shortcut for deployment.model.orogen_spec
            def orogen_spec; self.class.orogen_spec end

            # The name of the executable, i.e. the name of the deployment as
            # given in the oroGen file
            #
            # This  is a shortcut for deployment.model.deployment_name
            def deployment_name
                orogen_spec.name
            end

            # A name => Orocos::TaskContext instance mapping of all the task
            # contexts running on this deployment
            attr_reader :task_handles

            # The underlying Orocos::Process instance
            attr_reader :orogen_deployment

            ##
            # :method: ready_event
            #
            # Event emitted when the deployment is up and running
            event :ready

            ##
            # :method: signaled_event
            #
            # Event emitted whenever the deployment finishes because of a UNIX
            # signal. The event context is the Process::Status instance that
            # describes the termination
            #
            # It is forwarded to failed_event
            event :signaled
            forward :signaled => :failed

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
                plan.add(task = klass.new)
                task.robot = robot
                task.executed_by self
                task.orogen_spec = activity
                if ready?
                    task.orogen_task = task_handles[name]
                    task.orogen_task.process = orogen_deployment
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
                host = self.arguments['on'] ||= 'localhost'
                RobyPlugin.info { "starting deployment #{model.deployment_name} on #{host}" }

                process_server, log_dir = Orocos::RobyPlugin.process_servers[host]
                @orogen_deployment = process_server.start(model.deployment_name, :working_directory => log_dir)
                Deployment.all_deployments[@orogen_deployment] = self
                emit :start
            end

            def log_dir
                host = self.arguments['on'] ||= 'localhost'
                process_server, log_dir = Orocos::RobyPlugin.process_servers[host]
                log_dir
            end

            # The name of the machine this deployment is running on, i.e. the
            # name given to the :on argument.
            def machine
                arguments[:on] || 'localhost'
            end

            # Called when the process is finished.
            #
            # +result+ is the Process::Status object describing how this process
            # finished.
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
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orogen_task = nil
                end
            end

            # Removes any connection that points to tasks that were in this
            # process, and that are therefore dead because of the process
            # termination
            def cleanup_dead_connections
                return if !task_handles

                # task_handles is only initialized when ready is reached ...
                # so can be nil here
                all_tasks = task_handles.values.to_value_set
                all_tasks.each do |task|
                    task.each_parent_vertex(ActualDataFlow) do |parent_task|
                        if parent_task.process
                            next if !parent_task.process.running?
                            roby_task = Deployment.all_deployments[parent_task.process]
                            next if roby_task.finishing? || roby_task.finished?
                        end

                        mappings = parent_task[task, ActualDataFlow]
                        mappings.each do |(source_port, sink_port), policy|
                            if policy[:pull] # we have to disconnect explicitely
                                begin
                                    parent_task.port(source_port).disconnect_from(task.port(sink_port, false))
                                rescue Exception => e
                                    Orocos::RobyPlugin.warn "error while disconnecting #{parent_task}:#{source_port} from #{task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                                end
                            end
                        end
                    end
                    task.each_child_vertex(ActualDataFlow) do |child_task|
                        if child_task.process
                            next if !child_task.process.running?
                            roby_task = Deployment.all_deployments[child_task.process]
                            next if roby_task.finishing? || roby_task.finished?
                        end

                        mappings = task[child_task, ActualDataFlow]
                        mappings.each do |(source_port, sink_port), policy|
                            begin
                                child_task.port(sink_port).disconnect_all
                            rescue Exception => e
                                Orocos::RobyPlugin.warn "error while disconnecting #{task}:#{source_port} from #{child_task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                            end
                        end
                    end

                    ActualDataFlow.remove(task)
                    RequiredDataFlow.remove(task)
                end
            end

            poll do
                begin
                    next if ready?

                    if orogen_deployment.wait_running(0)
                        @task_handles = Hash.new
                        orogen_spec.task_activities.each do |activity|
                            task_handles[activity.name] = 
                                ::Orocos::TaskContext.get(activity.name)
                        end

                        if !arguments[:log] || State.orocos.deployment_excluded_from_log?(self)
                            Robot.info "not automatically logging any port in deployment #{name}"
                        else
                            Orocos::Process.log_all_ports(orogen_deployment,
                                        :log_dir => log_dir,
                                        :remote => (machine != 'localhost')) do |port|

                                result = !State.orocos.port_excluded_from_log?(self, Roby.app.orocos_tasks[port.task.model.name], port)
                                if !result
                                    Robot.info "not logging #{port.task.name}:#{port.name}"
                                end
                                result
                            end
                        end

                        each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                            task.orogen_task = task_handles[task.orocos_name]
                            task.orogen_task.process = orogen_deployment
                        end

                        emit :ready
                    end
                rescue Exception => e
                    STDERR.puts e.message
                    raise
                end
            end

	    def ready_to_die!
	    	@ready_to_die = true
	    end

	    attr_predicate :ready_to_die?

            ##
            # method: stop!
            #
            # Stops all tasks that are running on top of this deployment, and
            # kill the deployment
            event :stop do |context|
                to_be_killed = each_executed_task.find_all(&:running?)
                if to_be_killed.empty?
		    ready_to_die!
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
                terminal.on do |event|
		    ready_to_die!
		    orogen_deployment.kill(false)
		end
                # The stop event will get emitted after the process has been
                # killed. See the polling block.
            end

            # Creates a subclass of Deployment that represents the deployment
            # specified by +deployment_spec+.
            #
            # +deployment_spec+ is an instance of Orogen::Generation::Deployment
            def self.define_from_orogen(deployment_spec)
                klass = Class.new(Deployment)
                klass.instance_variable_set :@name, "Orocos::RobyPlugin::Deployments::#{deployment_spec.name.camelcase(true)}"
                klass.instance_variable_set :@orogen_spec, deployment_spec
                Orocos::RobyPlugin::Deployments.const_set(deployment_spec.name.camelcase(true), klass)
                klass
            end
        end

        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update(plan) # :nodoc:
            tasks = plan.find_tasks(RequirementModificationTask).running.to_a
            
            if Roby.app.orocos_engine.modified?
                # We assume that all requirement modification have been applied
                # by the RequirementModificationTask instances. They therefore
                # take the blame if something fails, and announce a success
                begin
                    Roby.app.orocos_engine.resolve
                    tasks.each do |t|
                        t.emit :success
                    end
                rescue Exception => e
                    if tasks.empty?
                        # No task to take the blame ... we'll have to shut down
                        raise 
                    end
                    tasks.each do |t|
                        t.emit(:failed, e)
                    end
                end
            end

            all_dead_deployments = ValueSet.new
            for name, server in Orocos::RobyPlugin.process_servers
                server = server.first
                if dead_deployments = server.wait_termination(0)
                    dead_deployments.each do |p, exit_status|
                        d = Deployment.all_deployments[p]
                        if !d.finishing?
                            Orocos::RobyPlugin.warn "#{p.name} unexpectedly died on #{name}"
                        end
                        all_dead_deployments << d
                        d.dead!(exit_status)
                    end
                end
            end

            for deployment in all_dead_deployments
                deployment.cleanup_dead_connections
            end

            if !(query = plan.instance_variable_get :@orocos_update_query)
                query = plan.find_tasks(Orocos::RobyPlugin::TaskContext).
                    not_finished.not_failed
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                next if !t.orogen_task
                # Some CORBA implementations (namely, omniORB) may behave weird
                # if the remote process terminates in the middle of a remote
                # call.
                #
                # Ignore tasks whose process is terminating
		if t.execution_agent.ready_to_die?
		    next
		end

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
                        default_values[p.name] =
                            if p.default_value
                                Typelib.from_ruby(p.default_value, p.type)
                            else
                                value = p.type.new
                                value.zero!
                                value
                            end

                        if p.type < Typelib::CompoundType || p.type < Typelib::ArrayType
                            attr_reader p.name
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
	    	if running?
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
                if orogen_spec.context.needs_configuration?
                    if !orogen_task
                        return false
                    else
                        state = read_current_state
                        if !state
                            return false
                        elsif !Roby.app.orocos_engine.dry_run? && state == :PRE_OPERATIONAL
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
		    begin
		        orogen_task.reset_error
		    rescue Orocos::StateTransitionFailed => e
			Robot.warn "cannot reset error on #{name}: #{e.message}"
		    end
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
	        Robot.info "interrupting #{name}"
                begin
                    orogen_task.stop
                rescue Orocos::CORBA::ComError
                    # We actually aborted
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
                        model = Orocos::RobyPlugin::DataSources.const_get model.to_str.camelcase(true)
                    rescue NameError
                        device_arguments, arguments = Kernel.filter_options arguments,
                            :provides => nil, :interface => nil

                        if !device_arguments[:provides] && !device_arguments[:interface]
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
                dserv = data_service(model, arguments)
                if !dserv.config_type
                    dserv.config_type = config_type_from_properties
                end
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
                    orogen_task.send("#{name}=", value)
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
                klass.instance_variable_set :@name, "Orocos::RobyPlugin::#{task_spec.component.name.camelcase(true)}::#{task_spec.basename.camelcase(true)}"
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

