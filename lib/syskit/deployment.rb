# The module in which all deployment models are defined
module Deployments
end

module Syskit
        class << self
            # (see RobyApp::Configuration#register_process_server)
            def register_process_server(name, client, log_dir = nil)
                Syskit.conf.register_process_server(name, client, log_dir = nil)
            end
        end

        # In oroGen, a deployment is a Unix process that holds a certain number
        # of task contexts. This Roby task represents the unix process itself.
        # Once it gets instanciated, the associated task contexts can be
        # accessed with #task(name)
        class Deployment < ::Roby::Task
            extend Models::Deployment
            extend Logger::Hierarchy
            include Logger::Hierarchy

            # The size of the buffered connection created between this object
            # and the remote task's state port
            STATE_READER_BUFFER_SIZE = 200

            argument :process_name, :default => from(:model).deployment_name
            argument :log, :default => true
            argument :on, :default => 'localhost'
            argument :name_mappings, :default => nil
            argument :spawn_options, :default=> nil
            argument :ready_polling_period, default: 0.1
            argument :logger_task, default: nil

            # The underlying process object
            attr_reader :orocos_process

            # An object describing the underlying pocess server
            #
            # @return [RobyApp::Configuration::ProcessServerConfig]
            def process_server_config
                @process_server_config ||= Syskit.conf.process_server_config_for(process_server_name)
            end

            def initialize(options = Hash.new)
                super

                @quit_ready_event_monitor = Concurrent::Event.new
                @remote_task_handles = Hash.new
                if !self.spawn_options
                    self.spawn_options = Hash.new
                end
                if !self.name_mappings
                    self.name_mappings = Hash.new
                end
                model.each_default_name_mapping do |k, v|
                    self.name_mappings[k] ||= v
                end
            end

            @@all_deployments = Hash.new
            class << self
                def all_deployments; @@all_deployments end
            end

            # The PID of this process
            def pid
                if running?
                    @pid ||= orocos_process.pid
                end
            end

            # Handles to all remote tasks from this deployment
            #
            # @return [Hash<String,RemoteTaskHandles>]
            attr_reader :remote_task_handles

            # The underlying Orocos::Process instance
            attr_reader :orocos_process

            # Event emitted when the deployment is up and running
            event :ready

            # Event emitted whenever the deployment finishes because of a UNIX
            # signal. The event context is the Process::Status instance that
            # describes the termination
            #
            # It is forwarded to failed_event
            event :signaled
            forward :signaled => :failed

            def instanciate_all_tasks
                model.each_orogen_deployed_task_context_model.map do |act|
                    task(name_mappings[act.name])
                end
            end

            # The list of deployed task contexts for this particular deployment
            #
            # It takes into account deployment prefix
            def each_orogen_deployed_task_context_model(&block)
                model.each_orogen_deployed_task_context_model(&block)
            end

            # Returns an task instance that represents the given task in this
            # deployment.
            def task(name, model = nil)
                if finishing? || finished?
                    raise InvalidState, "#{self} is either finishing or already finished, you cannot call #task"
                end

                orogen_task_deployment = each_orogen_deployed_task_context_model.
                    find { |act| name == name_mappings[act.name] }
                if !orogen_task_deployment
                    available = each_orogen_deployed_task_context_model.map { |act| name_mappings[act.name] }.sort.join(", ")
                    mappings  = name_mappings.map { |k,v| "#{k} => #{v}" }.join(", ")
                    raise ArgumentError, "no task called #{name} in #{self.class.deployment_name}, available tasks are #{available} using name mappings #{name_mappings}"
                end

                orogen_task_model = TaskContext.model_for(orogen_task_deployment.task_model)
                if model
                    if !(model <= orogen_task_model)
                        raise ArgumentError, "incompatible explicit selection #{model} for the model of #{name} in #{self}"
                    end
                else
                    model = orogen_task_model
                end
                plan.add(task = model.new(orocos_name: name_mappings[orogen_task_deployment.name]))
                task.executed_by self
                task.orogen_model = orogen_task_deployment
                if ready?
                    if remote_task = remote_task_handles[name]
                        task.initialize_remote_handles(remote_task)
                    else
                        raise InternalError, "no handle under then #{name} in #{self} for #{task} (got #{remote_task_handles.keys.sort.join(", ")})"
                    end
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
                if !process_name
                    raise ArgumentError, "must set process_name"
                end

                spawn_options = self.spawn_options
                options = (spawn_options[:cmdline_args] || Hash.new).dup
                model.each_default_run_option do |name, value|
                    options[name] = value
                end

                spawn_options = spawn_options.merge(
                    output: "%m-%p.txt", 
                    wait: false,
                    cmdline_args: options)

                if log_dir
                    spawn_options = spawn_options.merge(working_directory: log_dir)
                else
                    spawn_options.delete(:working_directory)
                end

                Deployment.info do
                    "starting deployment #{process_name} using #{model.deployment_name} on #{arguments[:on]} with #{spawn_options} and mappings #{name_mappings}"
                end

                @orocos_process = process_server_config.client.start(
                    process_name, model.orogen_model, name_mappings, spawn_options)

                Deployment.all_deployments[orocos_process] = self
                start_event.emit
            end

            def log_dir
                process_server_config.log_dir
            end

            # Returns this deployment's logger
            #
            # @return [TaskContext,nil] either the logging task, or nil if this
            #   deployment has none
            def logger_task
                if arguments[:logger_task]
                    @logger_task = arguments[:logger_task]
                elsif @logger_task && @logger_task.reusable?
                    @logger_task
                elsif process_name
                    logger_name = "#{process_name}_Logger"
                    @logger_task =
                        each_executed_task.find { |t| t.orocos_name == logger_name } ||
                            begin
                                task(logger_name)
                                # Automatic setup by {NetworkGeneration::LoggerConfigurationSupport}
                            rescue ArgumentError
                            end

                    if @logger_task
                        @logger_task.default_logger = true
                    end
                    @logger_task
                end
            end

            # How "far" this process is from the Syskit process
            #
            # @return one of the {TaskContext}::D_* constants
            def distance_to_syskit
                if in_process?
                    TaskContext::D_SAME_PROCESS
                elsif on_localhost?
                    TaskContext::D_SAME_HOST
                else
                    TaskContext::D_DIFFERENT_HOSTS
                end
            end

            # The name of the process server
            def process_server_name
                arguments[:on]
            end

            # The name of the host this deployment is running on, i.e. the
            # name given to the :on argument.
            def host_id
                process_server_config.host_id
            end

            # Whether this task runs within the Syskit process itself
            def in_process?
                process_server_config.in_process?
            end

            # Whether this deployment runs on the same host than the Syskit process
            def on_localhost?
                process_server_config.on_localhost?
            end

            # "How far" this deployment is from another
            #
            # It returns one of the TaskContext::D_ constants
            def distance_to(other_deployment)
                if other_deployment == self
                    TaskContext::D_SAME_PROCESS
                elsif other_deployment.host_id == host_id
                    if host_id == 'syskit'
                        TaskContext::D_SAME_PROCESS
                    else
                        TaskContext::D_SAME_HOST
                    end
                else
                    TaskContext::D_DIFFERENT_HOSTS
                end
            end

            # Returns true if the syskit plugin configuration requires
            # +port+ to be logged
            #
            # @param [Syskit::Port] port
            # @return [Boolean]
            def log_port?(port)
                if Syskit.conf.logs.port_excluded_from_log?(port)
                    false
                else
                    Syskit.info "not logging #{port.component}.#{port.name}"
                    true
                end
            end

            on :start do |event|
                handles_from_plan = Hash.new
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    if orocos_task = task.orocos_task
                        handles_from_plan[task.orocos_name] = orocos_task
                    end
                end
                schedule_ready_event_monitor(handles_from_plan)
            end

            # @api private
            #
            # Event used to quit the ready monitor started by
            # {#schedule_ready_event_monitor}
            #
            # @return [Concurrent::Event]
            attr_reader :quit_ready_event_monitor

            # @api private
            #
            # Schedule a promise to resolve the task handles
            #
            # It will reschedule itself until the process is ready, and will
            # emit the ready event when it happens
            def schedule_ready_event_monitor(handles_from_plan, ready_polling_period: self.ready_polling_period)
                distance_to_syskit = self.distance_to_syskit
                promise = execution_engine.promise(description: "#{self}:ready_event_monitor") do
                    while !quit_ready_event_monitor.set? && !(handles = orocos_process.resolve_all_tasks(handles_from_plan))
                        sleep ready_polling_period
                    end

                    (handles || Hash.new).map_value do |_, remote_task|
                        state_reader, state_getter = create_state_access(remote_task, distance: distance_to_syskit)
                        properties = remote_task.property_names.map do |p_name|
                            p = remote_task.raw_property(p_name)
                            [p, p.raw_read]
                        end
                        current_configuration = CurrentTaskConfiguration.new(nil, [], Set.new)
                        RemoteTaskHandles.new(remote_task, state_reader, state_getter, properties, false, current_configuration)
                    end
                end.on_success(description: "#{self}#schedule_ready_event_monitor#emit") do |remote_tasks|
                    if running? && !finishing? && remote_tasks
                        @remote_task_handles = remote_tasks
                        ready_event.emit
                    end
                end
                promise.on_error(description: "#{self}#emit_failed") do |reason|
                    if !finishing? || !finished?
                        emit_failed(reason)
                    end
                end
                ready_event.achieve_asynchronously(promise, emit_on_success: false, on_failure: :nothing)
            end

            on :ready do |event|
                setup_task_handles(remote_task_handles)
            end

            # @api private
            #
            # Representation of the handles needed by {Syskit::TaskContext} to
            # get state updates from a remote task
            #
            # They are initialized once and for all since they won't change
            # across TaskContext restarts, allowing us to save costly
            # back-and-forth between the remote task and the local process
            RemoteTaskHandles = Struct.new :handle, :state_reader, :state_getter, :default_properties, :configuring, :current_configuration

            # @api private
            #
            # The last applied task configuration
            CurrentTaskConfiguration = Struct.new :model, :conf, :dynamic_services

            # @api private
            #
            # Whether one of this deployment's task is being configured
            def configuring?(orocos_name)
                remote_task_handles[orocos_name].configuring
            end

            # @api private
            #
            # Declare that the given task is being configured
            def start_configuration(orocos_name)
                remote_task_handles[orocos_name].configuring = true
            end

            # @api private
            #
            # Declare that the given task is being configured
            def finished_configuration(orocos_name)
                remote_task_handles[orocos_name].configuring = false
            end

            # @api private
            #
            # The currently applied configuration for the given task
            def configuration_changed?(orocos_name, conf, dynamic_services)
                current = remote_task_handles[orocos_name].current_configuration
                current.conf != conf ||
                    current.dynamic_services != dynamic_services.to_set
            end

            # @api private
            #
            # Update the last known configuration of a task
            def update_current_configuration(orocos_name, model, conf, current_dynamic_services)
                remote_task_handles[orocos_name].
                    current_configuration = CurrentTaskConfiguration.new(model, conf, current_dynamic_services)
            end

            # @api private
            #
            # Mark tasks affected by a change in configuration section as
            # non-reusable
            def mark_changed_configuration_as_not_reusable(changed)
                needed = Set.new
                remote_task_handles.each do |orocos_name, remote_handle|
                    current_conf = remote_handle.current_configuration
                    if modified_sections = changed[current_conf.model.concrete_model]
                        if modified_sections.any? { |section_name| current_conf.conf.include?(section_name) }
                            needed << orocos_name
                        end
                    end
                end

                TaskContext.needs_reconfiguration.merge(needed)
                needed
            end

            # @api private
            def setup_task_handles(remote_tasks)
                model.each_orogen_deployed_task_context_model do |act|
                    name = orocos_process.get_mapped_name(act.name)
                    if !remote_tasks.has_key?(name)
                        raise InternalError, "expected #{orocos_process}'s reported tasks to include mapped_task_name, but got handles only for invalid_name"
                    end
                end
                
                remote_tasks.each_value do |task|
                    task.handle.process = nil
                end

                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    if remote_handles = remote_tasks[task.orocos_name]
                        task.initialize_remote_handles(remote_handles)
                    else
                        task.failed_to_start!(
                            Roby::CommandFailed.new(
                                InternalError.exception("#{task} is supported by #{self} but there does not seem to be any task called #{task.orocos_name} on this deployment"),
                                task.start_event))
                    end
                end
            end

            # @api private
            #
            # Called asynchronously to initialize the {RemoteTaskHandles} object
            # once and for all
            def create_state_access(remote_task, distance: TaskContext::D_UNKNOWN)
                state_getter = RemoteStateGetter.new(
                    remote_task,
                    initial_state: remote_task.rtt_state)

                if remote_task.model.extended_state_support?
                    state_port = remote_task.raw_port('state')
                    state_reader = state_port.reader(
                        type: :buffer, size: STATE_READER_BUFFER_SIZE, init: true,
                        distance: distance)
                    state_reader.extend Orocos::TaskContext::StateReader
                    state_reader.state_symbols = remote_task.state_symbols
                else
                    state_reader = state_getter
                end
                return state_reader, state_getter
            end

	    attr_predicate :ready_to_die?

	    def ready_to_die!
	    	@ready_to_die = true
	    end

            ##
            # method: stop!
            #
            # Stops all tasks that are running on top of this deployment, and
            # kill the deployment
            event :stop do |context|
                quit_ready_event_monitor.set
                promise = execution_engine.promise(description: "#{self}.stop_event.on") do
                    begin
                        remote_task_handles.each_value do |remote_task|
                            remote_task.state_getter.disconnect
                            if remote_task.handle.rtt_state == :STOPPED
                                remote_task.handle.cleanup(false)
                            end
                        end
                        remote_task_handles.each_value do |remote_task|
                            remote_task.state_getter.join
                        end
                    rescue Orocos::ComError
                        # Assume that the process is killed as it is not reachable
                    end
                end.on_success(description: "#{self}#stop_event#command#dead!") do
                    ready_to_die!
                    begin
                        orocos_process.kill(false)
                    rescue Orocos::ComError
                        # The underlying process server cannot be reached. Just emit
                        # failed ourselves
                        dead!(nil)
                    end
                end
                stop_event.achieve_asynchronously(promise, emit_on_success: false)
            end

            # Called when the process is finished.
            #
            # +result+ is the Process::Status object describing how this process
            # finished.
            def dead!(result)
                if !result
                    failed_event.emit
                elsif history.find(&:terminal?)
                    # Do nothing. A terminal event already happened, so we don't
                    # need to tell what kind of end this is for the system
                    stop_event.emit
                elsif result.success?
                    success_event.emit
                elsif result.signaled?
                    signaled_event.emit result
                else
                    failed_event.emit result
                end

                Deployment.all_deployments.delete(orocos_process)
                model.each_orogen_deployed_task_context_model do |act|
                    name = orocos_process.get_mapped_name(act.name)
                end

                # do NOT call cleanup_dead_connections here.
                # Runtime.update_deployment_states will first announce all the
                # dead processes and only then call #cleanup_dead_connections,
                # thus avoiding to disconnect connections between already-dead
                # processes
            end

            # Returns the deployment object that matches the given process
            # object
            # 
            # @param process the deployment's process object. Note that it is
            #   usually not a Ruby Process object, but a process representation
            #   from orocosrb's process server infrastructure
            def self.deployment_by_process(process)
                all_deployments.fetch(process)
            end
        end
end


