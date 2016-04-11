# The module in which all deployment models are defined
module Deployments
end

module Syskit
    module TaskContextPeekStateInterdiction
        def peek_current_state
            Syskit.fatal "#peek_current_state called on #{self}"
            caller.each do |line|
                Syskit.fatal "  #{line}"
            end
            super
        end
    end

    Orocos::TaskContext.send :prepend, TaskContextPeekStateInterdiction

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

            argument :process_name, :default => from(:model).deployment_name
            argument :log, :default => true
            argument :on, :default => 'localhost'
            argument :name_mappings, :default => nil
            argument :spawn_options, :default=> nil

            # An object describing the underlying pocess server
            #
            # @return [RobyApp::Configuration::ProcessServerConfig]
            def process_server_config
                @process_server_config ||= Syskit.conf.process_server_config_for(host)
            end

            def initialize(options = Hash.new)
                super
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

            # A name => Orocos::TaskContext instance mapping of all the task
            # contexts running on this deployment
            attr_reader :task_handles

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

            # Returns true if +self+ and +task+ are running on the same process
            # server
            def on_same_server?(task)
                task == self || host == task.host
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

            # Returns an task instance that represents the given task in this
            # deployment.
            def task(name, model = nil)
                if finishing? || finished?
                    raise ArgumentError, "#{self} is either finishing or already finished, you cannot call #task"
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
                plan.add(task = model.new(:orocos_name => name_mappings[orogen_task_deployment.name]))
                task.executed_by self
                task.orogen_model = orogen_task_deployment
                if ready?
                    if orocos_task = task_handles[name]
                        initialize_running_task(task, orocos_task)
                    else
                        raise Internal, "no handle under then #{name} in #{self} for #{task}"
                    end
                end
                task
            end

            # Internal helper to set the #orocos_task
            def initialize_running_task(task, orocos_task)
                task.orocos_task = orocos_task
                if task.orocos_task.respond_to?(:model=)
                    task.orocos_task.model = task.model.orogen_model
                end
                if Syskit.conf.conf_log_enabled?
                    task.orocos_task.log_all_configuration(Orocos.configuration_log)
                end
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
                    "starting deployment #{process_name} using #{model.deployment_name} on #{host} with #{spawn_options} and mappings #{name_mappings}"
                end

                @orocos_process = process_server_config.client.start(
                    process_name, model.orogen_model, name_mappings, spawn_options)

                Deployment.all_deployments[@orocos_process] = self
                start_event.emit
            end

            def log_dir
                process_server_config.log_dir
            end

            # The name of the host this deployment is running on, i.e. the
            # name given to the :on argument.
            def host
                arguments[:on]
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

            poll do
                next if ready?

                if orocos_process.wait_running(0)
                    ready_event.emit

                    @task_handles = Hash.new
                    each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                        if orocos_task = task.orocos_task
                            task_handles[task.orocos_name] = orocos_task
                        end
                    end

                    errors = Hash.new
                    model.each_orogen_deployed_task_context_model do |activity|
                        name = orocos_process.get_mapped_name(activity.name)
                        if !task_handles[name]
                            begin
                                orocos_task = orocos_process.task(name)
                            rescue ArgumentError => e
                                errors[name] = e
                                next
                            end

                            orocos_task.process = orocos_process
                            task_handles[name] =  orocos_task
                        end
                    end

                    each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                        if error = errors[task.orocos_name]
                            task.failed_to_start!(error)
                        elsif orocos_task = task_handles[task.orocos_name]
                            initialize_running_task(task, orocos_task)
                        else
                            raise Internal, "#{task} is supported by #{self} but there does not seem to be any task called #{task.orocos_name} on #{self}"
                        end
                    end
                end
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
                begin
                    if task_handles
                        task_handles.each_value do |t|
                            if t.rtt_state == :STOPPED
                                t.cleanup(false)
                            end
                        end
                    end
                rescue Orocos::ComError
                    # Assume that the process is killed as it is not reachable
                end
                ready_to_die!
                begin
                    orocos_process.kill(false)
                rescue Orocos::ComError
                    # The underlying process server cannot be reached. Just emit
                    # failed ourselves
                    dead!(nil)
                end
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
                    TaskContext.configured.delete(name)
                end
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orocos_task = nil
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


