# frozen_string_literal: true

# The module in which all deployment models are defined
module Deployments
end

module Syskit
    class << self
        # (see RobyApp::Configuration#register_process_server)
        def register_process_server(name, client, log_dir = nil)
            Syskit.conf.register_process_server(name, client, log_dir)
        end
    end

    # In oroGen, a deployment is a Unix process that holds a certain number
    # of task contexts. This Roby task represents the unix process itself.
    # Once it gets instanciated, the associated task contexts can be
    # accessed with #task(name)
    class Deployment < ::Roby::Task # rubocop:disable Metrics/ClassLength
        extend Models::Deployment
        extend Logger::Hierarchy
        include Logger::Hierarchy

        # The size of the buffered connection created between this object
        # and the remote task's state port
        STATE_READER_BUFFER_SIZE = 200

        argument :process_name, default: from(:model).deployment_name
        argument :log, default: true
        argument :on, default: "localhost"
        argument :name_mappings, default: nil
        argument :spawn_options, default: nil
        argument :ready_polling_period, default: 0.1
        argument :logger_task, default: nil
        argument :logger_name, default: nil
        argument :logging_enabled, default: nil
        argument :read_only, default: nil

        # The underlying process object
        attr_reader :orocos_process

        # An object describing the underlying pocess server
        #
        # @return [RobyApp::Configuration::ProcessServerConfig]
        def process_server_config
            @process_server_config ||=
                Syskit.conf.process_server_config_for(process_server_name)
        end

        def initialize(**options)
            super

            @has_fatal_errors = false
            @has_quarantines = false
            @quit_ready_event_monitor = Concurrent::Event.new
            @remote_task_handles = {}
            self.read_only = [] unless read_only
            self.spawn_options = {} unless spawn_options
            self.name_mappings = {} unless name_mappings
            model.each_default_name_mapping do |k, v|
                name_mappings[k] ||= v
            end
        end

        @@all_deployments = {}
        class << self
            def all_deployments
                @@all_deployments
            end
        end

        # The PID of this process
        def pid
            @pid ||= orocos_process.pid if running?
        end

        # Handles to all remote tasks from this deployment
        #
        # @return [Hash<String,RemoteTaskHandles>]
        attr_reader :remote_task_handles

        # Event emitted when the deployment is up and running
        event :ready

        # Event emitted whenever the deployment finishes because of a UNIX
        # signal. The event context is the Process::Status instance that
        # describes the termination
        #
        # It is forwarded to failed_event
        event :signaled
        forward :signaled => :failed

        def has_orocos_name?(orocos_name)
            name_mappings.each_value.any? { |n| n == orocos_name }
        end

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

        # Either find the existing task that matches the given deployment specification,
        # or creates and adds it.
        #
        # @param (see #task)
        def find_or_create_task(name, syskit_task_model = nil, auto_conf: false)
            orogen_task_deployment_model = deployed_orogen_model_by_name(name)
            if orogen_master = orogen_task_deployment_model.master
                mapped_master = name_mappings[orogen_master.name]
                scheduler_task = find_or_create_task(
                    mapped_master, auto_conf: true
                )
                candidates = scheduler_task.each_parent_task
            else
                candidates = each_executed_task
            end

            # I don't know why name_mappings[orogen.name] would not be
            # equal to 'name' and I couldn't find a reason for this in the
            # git history when I refactored this.
            #
            # I keep it here for now, just in case, but that would need to
            # be investigated
            #
            # TODO
            mapped_name = name_mappings[orogen_task_deployment_model.name]
            candidates.each do |task|
                return task if task.orocos_name == mapped_name
            end

            create_deployed_task(
                orogen_task_deployment_model,
                syskit_task_model,
                scheduler_task, auto_conf: auto_conf
            )
        end

        def deployed_orogen_model_by_name(name)
            orogen_task_deployment =
                each_orogen_deployed_task_context_model
                .find { |act| name == name_mappings[act.name] }
            unless orogen_task_deployment
                available = each_orogen_deployed_task_context_model
                            .map { |act| name_mappings[act.name] }
                            .sort.join(", ")
                mappings = name_mappings
                           .map { |k, v| "#{k} => #{v}" }.join(", ")
                raise ArgumentError,
                      "no task called #{name} in "\
                      "#{self.class.deployment_name}, available tasks are "\
                      "#{available} using name mappings #{mappings}"
            end
            orogen_task_deployment
        end

        def deployed_model_by_orogen_model(orogen_model)
            TaskContext.model_for(orogen_model.task_model)
        end

        # @api private
        #
        # Create and add a task model supported by this deployment
        #
        # @param [OroGen::Spec::TaskDeployment] orogen_task_deployment_model
        #   the orogen model that describes this
        #   deployment
        # @param [Models::TaskContext,nil] syskit_task_model the expected
        #   syskit task model, or nil if it is meant to use the basic model.
        #   This is useful in specialized models (e.g. dynamic services)
        # @param [Deployment,TaskContext] syskit_execution_agent the task
        #   that will be used as an execution agent. this is usually self,
        #   but may be a task in master/slave relationships.
        # @param [Boolean] auto_conf if true, the method will attempt to select
        #   a configuration that matches the task's orocos name (if it exists). This
        #   is mostly used for scheduling tasks, which are automatically instanciated
        #   by Syskit.
        #
        # @see find_or_create_task task
        def create_deployed_task(
            orogen_task_deployment_model,
            syskit_task_model, scheduler_task, auto_conf: false
        )
            mapped_name = name_mappings[orogen_task_deployment_model.name]
            if ready?
                unless (remote_handles = remote_task_handles[mapped_name])
                    raise InternalError,
                          "no remote handle describing #{mapped_name} in #{self}"\
                          "(got #{remote_task_handles.keys.sort.join(', ')})"
                end
            end

            if task_context_in_fatal?(mapped_name)
                raise TaskContextInFatal.new(self, mapped_name),
                      "trying to create task for FATAL_ERROR component #{mapped_name} "\
                      "from #{self}"
            end

            base_syskit_task_model = deployed_model_by_orogen_model(
                orogen_task_deployment_model
            )
            syskit_task_model ||= base_syskit_task_model
            unless syskit_task_model <= base_syskit_task_model
                raise ArgumentError,
                      "incompatible explicit selection of task model "\
                      "#{syskit_task_model} for the model of #{mapped_name} in #{self}, "\
                      "expected #{base_syskit_task_model} or one of its subclasses"
            end

            task = syskit_task_model
                   .new(orocos_name: mapped_name, read_only: read_only?(mapped_name))
            plan.add(task)
            task.executed_by self
            if scheduler_task
                task.depends_on scheduler_task, role: "scheduler"
                task.should_configure_after scheduler_task.start_event
            end

            task.orogen_model = orogen_task_deployment_model
            task.initialize_remote_handles(remote_handles) if remote_handles
            auto_select_conf(task) if auto_conf
            task
        end

        def read_only?(mapped_name)
            read_only.include?(mapped_name)
        end

        # Returns an task instance that represents the given task in this
        # deployment.
        #
        # @param [String] name the unmapped name of the task
        # @param [Models::TaskContext,nil] syskit_task_model the Syskit
        #   model that should be used to create the task, if it is not the
        #   same as the base model. This is used for specialized models (e.g.
        #   dynamic services)
        def task(name, syskit_task_model = nil)
            if finishing? || finished?
                raise InvalidState,
                      "#{self} is either finishing or already "\
                      "finished, you cannot call #task"
            end

            orogen_task_deployment_model = deployed_orogen_model_by_name(name)

            if (orogen_master = orogen_task_deployment_model.master)
                scheduler_task = find_or_create_task(
                    orogen_master.name, auto_conf: true
                )
            end
            create_deployed_task(
                orogen_task_deployment_model,
                syskit_task_model, scheduler_task
            )
        end

        # Selects the configuration of a master task
        #
        # Master tasks are auto-injected in the network, and as such the
        # user cannot select their configuration. This picks either
        # ['default', task.orocos_name] if the master task's has a configuration
        # section matching the task's name, or ['default'] otherwise.
        private def auto_select_conf(task)
            manager = task.model.configuration_manager
            task.conf =
                if manager.has_section?(task.orocos_name)
                    ["default", task.orocos_name]
                else
                    ["default"]
                end
        end

        ##
        # method: start!
        #
        # Starts the process and emits the start event immediately. The
        # :ready event will be emitted when the deployment is up and
        # running.
        event :start do |_context|
            raise ArgumentError, "must set process_name" unless process_name

            spawn_options = self.spawn_options
            options = (spawn_options[:cmdline_args] || {}).dup
            model.each_default_run_option do |name, value|
                options[name] = value
            end

            spawn_options = spawn_options.merge(
                output: "%m-%p.txt",
                wait: false,
                cmdline_args: options
            )

            if log_dir
                spawn_options = spawn_options.merge(working_directory: log_dir)
            else
                spawn_options.delete(:working_directory)
            end

            Deployment.info do
                "starting deployment #{process_name} using "\
                "#{model.deployment_name} on #{arguments[:on]} with "\
                "#{spawn_options} and mappings #{name_mappings}"
            end

            @orocos_process = process_server_config.client.start(
                process_name, model.orogen_model, name_mappings, **spawn_options
            )

            Deployment.all_deployments[orocos_process] = self
            start_event.emit
        end

        # Create the spawn options needed to start this deployment for the
        # given configuration
        #
        # @return [Orocos::Process::CommandLine]
        def self.command_line(
            name, name_mappings,
            working_directory: Roby.app.log_dir,
            log_level: nil,
            cmdline_args: {},
            tracing: false,
            gdb: nil,
            valgrind: nil,
            name_service_ip: "localhost",
            loader: Roby.app.default_pkgconfig_loader
        )

            cmdline_args = cmdline_args.dup
            each_default_run_option do |option_name, option_value|
                unless cmdline_args.key?(option_name)
                    cmdline_args[option_name] = option_value
                end
            end

            process = Orocos::Process.new(
                name, orogen_model,
                loader: loader,
                name_mappings: name_mappings
            )
            process.command_line(
                working_directory: working_directory,
                log_level: log_level,
                cmdline_args: cmdline_args,
                tracing: tracing,
                gdb: gdb,
                valgrind: valgrind,
                name_service_ip: name_service_ip
            )
        end

        def log_dir
            process_server_config.log_dir
        end

        def logger_name
            arguments[:logger_name] || ("#{process_name}_Logger" if process_name)
        end

        # Returns this deployment's logger
        #
        # @return [TaskContext,nil] either the logging task, or nil if this
        #   deployment has none
        def logger_task
            return unless logging_enabled?

            if arguments[:logger_task]
                @logger_task = arguments[:logger_task]
            elsif @logger_task&.reusable?
                @logger_task
            elsif (logger_name = self.logger_name)
                logger_task = each_executed_task
                              .find { |t| t.orocos_name == logger_name }
                @logger_task =
                    if logger_task&.fullfills?(LoggerService)
                        logger_task
                    else
                        instanciate_default_logger_task(logger_name)
                    end

                @logger_task&.default_logger = true
                @logger_task
            end
        end

        # Instanciates a new default logger
        #
        # @return [Syskit::TaskContext,nil] the instanciated task, or nil if
        #   no matching task can be found in this deployment
        def instanciate_default_logger_task(logger_name)
            begin
                orogen_model = deployed_orogen_model_by_name(logger_name)
            rescue ArgumentError # Does not exist
                return
            end

            syskit_model = deployed_model_by_orogen_model(orogen_model)
            return unless syskit_model.fullfills?(LoggerService)

            # Automatic setup by
            # {NetworkGeneration::LoggerConfigurationSupport}
            task(logger_name)
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
                if host_id == "syskit"
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

        # @api private
        #
        # Event used to quit the ready monitor started by
        # {#schedule_ready_event_monitor}
        #
        # @return [Concurrent::Event]
        attr_reader :quit_ready_event_monitor

        # @api private
        # This schedules an asynchronous process to connect to the tasks before
        # ready is emitted. I.e. the process is not ready after the method returns.
        #
        # @param [{String=>String}] ior_mappings the mappings of the form
        #   { task_name => ior }. This is necessary because the Syskit remote process has
        #   no information about the IORs until now.
        def update_remote_tasks(ior_mappings)
            orocos_process.define_ior_mappings(ior_mappings)
            begin
                remote_tasks = orocos_process.resolve_all_tasks
            rescue Orocos::IORNotRegisteredError, ArgumentError => e
                ready_event.emit_failed(e)
                return
            end

            promise = execution_engine.promise(
                description: "#{self}#update_remote_tasks#resolve handles"
            ) do
                resolve_remote_task_handles(remote_tasks)
            end
            promise.on_success(
                description: "#{self}#update_remote_tasks#success"
            ) do |remote_task_handles|
                if running? && !finishing?
                    @remote_task_handles = remote_task_handles
                    ready_event.emit
                end
            end
            promise.on_error(description: "#{self}#emit_failed") do |reason|
                ready_event.emit_failed(reason) unless finishing? || finished?
            end
            ready_event.pending([])
            ready_event.achieve_asynchronously(
                promise, emit_on_success: false, on_failure: :nothing
            )
        end

        def resolve_remote_task_handles(remote_tasks)
            return if quit_ready_event_monitor.set?

            remote_tasks.transform_values do |remote_task|
                state_reader, state_getter =
                    create_state_access(remote_task, distance: distance_to_syskit)
                properties = remote_task.property_names.map do |p_name|
                    p = remote_task.raw_property(p_name)
                    [p, p.raw_read.freeze]
                end
                current_configuration = CurrentTaskConfiguration.new(nil, [], Set.new)
                RemoteTaskHandles.new(
                    remote_task, state_reader, state_getter,
                    properties, false, current_configuration
                )
            end
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
        RemoteTaskHandles = Struct.new(
            :handle, :state_reader, :state_getter, :default_properties,
            :configuring, :current_configuration, :needs_reconfiguration,
            :in_fatal, :quarantined
        )

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
        # Declare that the given task transitioned to FATAL_ERROR
        #
        # This will trigger sanity checks if attempting to spawn it again
        def register_task_context_in_fatal(orocos_name)
            @has_fatal_errors = true
            remote_task_handles[orocos_name.to_str].in_fatal = true
        end

        # Tests whether a given task context is in FATAL_ERROR
        def task_context_in_fatal?(orocos_name)
            return false unless ready?

            remote_task_handles[orocos_name.to_str].in_fatal
        end

        # Whether some components of this deployment are in FATAL
        def has_fatal_errors?
            @has_fatal_errors
        end

        # @api private
        #
        # Declare that the given task has become quarantined
        def register_task_context_quarantined(orocos_name)
            @has_quarantines = true
            remote_task_handles[orocos_name.to_str].quarantined = true
        end

        # Tests whether a given task context is quarantined
        def task_context_quarantined?(orocos_name)
            return false unless ready?

            remote_task_handles[orocos_name.to_str].quarantined
        end

        # Whether some components of this deployment are quarantined
        #
        # This happens when they fail to stop
        def has_quarantines?
            @has_quarantines
        end

        # @api private
        #
        # The currently applied configuration for the given task
        def configuration_changed?(orocos_name, conf, dynamic_services)
            current = remote_task_handles[orocos_name].current_configuration
            return true if current.conf != conf

            current_services = current.dynamic_services.group_by(&:name)
            dynamic_services.each do |srv|
                return true unless (current_srv = current_services.delete(srv.name))
                return true unless current_srv.first.same_service?(srv)
            end
            false
        end

        # @api private
        #
        # Update the last known configuration of a task
        def update_current_configuration(
            orocos_name, model, conf, current_dynamic_services
        )
            task_info = remote_task_handles[orocos_name]
            task_info.needs_reconfiguration = false
            task_info.current_configuration =
                CurrentTaskConfiguration.new(model, conf, current_dynamic_services)
        end

        # Force reconfiguration for all tasks in a plan that match the given
        # orocos name
        def self.needs_reconfiguration!(plan, orocos_name)
            plan.find_local_tasks(Syskit::Deployment)
                .each do |deployment_task|
                    if deployment_task.has_orocos_name?(orocos_name)
                        deployment_task.needs_reconfiguration!(orocos_name)
                    end
                end
        end

        # @api private
        #
        # Whether a task should be forcefully reconfigured during the next
        # network adaptation
        def needs_reconfiguration?(orocos_name)
            remote_task_handles[orocos_name]&.needs_reconfiguration
        end

        # @api private
        #
        # Force a task to be reconfigured during the next network adaptation
        def needs_reconfiguration!(orocos_name)
            remote_task_handles[orocos_name]&.needs_reconfiguration = true
        end

        # List of task (orocos names) that are marked as needing
        # reconfiguration
        def pending_reconfigurations
            remote_task_handles.keys.find_all do |orocos_name|
                remote_task_handles[orocos_name].needs_reconfiguration
            end
        end

        # @api private
        #
        # Mark tasks affected by a change in configuration section as
        # non-reusable
        def mark_changed_configuration_as_not_reusable(changed)
            needed = Set.new
            remote_task_handles.each do |orocos_name, remote_handle|
                current_conf = remote_handle.current_configuration
                next if current_conf.conf.empty?

                modified_sections = changed[current_conf.model.concrete_model]
                next unless modified_sections

                affects_this_task =
                    modified_sections
                    .any? { |section_name| current_conf.conf.include?(section_name) }
                if affects_this_task
                    needed << orocos_name
                    remote_handle.needs_reconfiguration = true
                end
            end
            needed
        end

        # @api private
        def setup_task_handles(remote_tasks)
            model.each_orogen_deployed_task_context_model do |act|
                name = orocos_process.get_mapped_name(act.name)
                unless remote_tasks.key?(name)
                    raise InternalError,
                          "expected #{orocos_process}'s reported tasks to "\
                          "include '#{name}' (mapped from '#{act.name}'), "\
                          "but got handles only for "\
                          "#{remote_tasks.keys.sort.join(' ')}"
                end
            end

            remote_tasks.each_value do |task|
                task.handle.process = nil
            end

            each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                if (remote_handles = remote_tasks[task.orocos_name])
                    task.initialize_remote_handles(remote_handles)
                else
                    root_exception = InternalError.exception(
                        "#{task} is supported by #{self} but there does "\
                        "not seem to be any task called #{task.orocos_name} "\
                        "on this deployment"
                    )
                    task.failed_to_start!(
                        Roby::CommandFailed.new(root_exception, task.start_event)
                    )
                end
            end
        end

        # @api private
        #
        # Called asynchronously to initialize the {RemoteTaskHandles} object
        # once and for all
        def create_state_access(remote_task, distance: TaskContext::D_UNKNOWN)
            state_getter = RemoteStateGetter.new(remote_task)

            if remote_task.model.extended_state_support?
                state_port = remote_task.raw_port("state")
                state_reader = state_port.reader(
                    type: :buffer, size: STATE_READER_BUFFER_SIZE, init: true,
                    distance: distance
                )
                state_reader.extend Orocos::TaskContext::StateReader
                state_reader.state_symbols = remote_task.state_symbols
            else
                state_getter.start
                state_getter.pause
                state_reader = state_getter
            end
            [state_reader, state_getter]
        end

        attr_predicate :ready_to_die?

        def ready_to_die!
            @ready_to_die = true
        end

        ##
        # method: kill!
        #
        # Hard-kill the process, without attempting to stop or cleanup the tasks
        # it supports
        event :kill, terminal: true do |_context|
            remote_task_handles = stop_prepare
            promise = self.promise(description: "#{self}#kill")
            stop_kill(promise, remote_task_handles)
            kill_event.achieve_asynchronously(promise, emit_on_success: false)
        end

        forward kill: :failed

        ##
        # method: stop!
        #
        # Stops all tasks that are running on top of this deployment, and
        # kill the deployment
        event :stop do |_context|
            # This is a heuristic added after the introduction of the kill
            # event command. It's meant to guess whether we should kill or cleanly
            # stop the deployment.
            #
            # The assumption is that:
            # - if there are fatal errors, we aren't sure about the state of all
            #   tasks, and we might even have some state transitions still being
            #   processed.
            # - if there are running tasks, we either aren't going through the
            #   normal, GC-based teardown process or we have quarantined tasks
            #   that haven't stopped.
            has_running_tasks = each_executed_task.any? { |t| !t.finished? }
            return kill! if has_running_tasks || has_fatal_errors? || has_quarantines?

            remote_task_handles = stop_prepare
            promise = self.promise(description: "#{self}#stop")
            stop_cleanly(promise, remote_task_handles)
            stop_event.achieve_asynchronously(promise, emit_on_success: false)
        end

        def stop_prepare
            quit_ready_event_monitor.set
            remote_task_handles = self.remote_task_handles.dup
            remote_task_handles.each_value do |remote_task|
                remote_task.state_getter.disconnect
            end
            remote_task_handles
        end

        def stop_cleanly(promise, remote_task_handles)
            promise.then(description: "#{self}.stop_event - cleaning RTT tasks") do
                remote_task_handles.each do |mapped_name, remote_task|
                    next if read_only?(mapped_name)

                    begin
                        if remote_task.handle.rtt_state == :STOPPED
                            remote_task.handle.cleanup(false)
                        end
                    rescue Orocos::ComError
                        # Assume that the process is killed as it is not reachable
                    end
                end
            end

            stop_kill(promise, remote_task_handles, hard: false)
        end

        def stop_kill(promise, remote_task_handles, hard: true)
            promise.then(description: "#{self}.stop_event - join state getters") do
                remote_task_handles.each_value do |remote_task|
                    remote_task.state_getter.join
                end
            end.on_success(description: "#{self}#stop_event - kill") do
                ready_to_die!
                begin
                    orocos_process.kill(false, cleanup: false, hard: hard)
                rescue Orocos::ComError
                    # The underlying process server cannot be reached. Just emit
                    # failed ourselves
                    dead!(nil)
                end
            end
        end

        # Called when the process is finished.
        #
        # +result+ is the Process::Status object describing how this process
        # finished.
        def dead!(result)
            kill_event.emit if kill_event.pending?

            if history.find(&:terminal?)
                # Do nothing. A terminal event already happened, so we don't
                # need to tell what kind of end this is for the system
                stop_event.emit
            elsif !result
                failed_event.emit
            elsif result.success?
                success_event.emit
            elsif result.signaled?
                signaled_event.emit result
            else
                failed_event.emit result
            end

            Deployment.all_deployments.delete(orocos_process)

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

        # @api private
        #
        # Kill this task's execution agent if self is the only non-utility task
        # it currently supports
        #
        # "Utility" tasks are tasks that are there in support of the overall
        # Syskit system, such as e.g. loggers
        #
        # @return [Boolean] true if the agent is either already finished, finalized
        #   or if the method stopped it. false if the agent is present and running
        #   and the task could not terminate it
        def opportunistic_recovery_from_quarantine
            return unless has_fatal_errors? || has_quarantines?

            each_executed_task do |t|
                next if t.quarantined?
                next if t.finished?
                next if Roby.app.syskit_utility_component?(t)

                return
            end

            # Avoid generating an error.
            each_executed_task do |t|
                plan.unmark_permanent_task(t)
            end
            plan.unmark_permanent_task(self)

            # We aren't really so sure about the overall state of things.
            #
            # What could be stopped cleanly has been stopped cleanly (not
            # cleaned up, but stopped). Kill the process to avoid further damage
            kill! if running?
        end

        def logging_enabled?
            if logging_enabled.nil?
                process_server_config.logging_enabled?
            else
                logging_enabled
            end
        end
    end
end
