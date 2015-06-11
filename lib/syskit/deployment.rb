# The module in which all deployment models are defined
module Deployments
end

module Syskit
        class << self
            # (see RobyApp::Configuration#register_process_server)
            def register_process_server(name, client, log_dir)
                Syskit.conf.register_process_server(name, client, log_dir)
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
                    initialize_running_task(task, task_handles[name])
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
                    :working_directory => log_dir, 
                    :output => "%m-%p.txt", 
                    :wait => false,
                    :cmdline_args => options)

                Deployment.info { "starting deployment #{process_name} using #{model.deployment_name} on #{host} with #{spawn_options} and mappings #{name_mappings}" }

                @orocos_process = process_server_config.client.start(
                    process_name, model.orogen_model, name_mappings, spawn_options)

                Deployment.all_deployments[@orocos_process] = self
                emit :start
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
                result = !Syskit.conf.port_excluded_from_log?(self, port)
                if !result
                    Syskit.info "not logging #{port.component}.#{port.name}"
                end
                result
            end

            poll do
                next if ready?

                if orocos_process.wait_running(0)
                    emit :ready

                    @task_handles = Hash.new
                    each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                        task_handles[task.orocos_name] = task.orocos_task
                    end

                    model.each_orogen_deployed_task_context_model do |activity|
                        name = orocos_process.get_mapped_name(activity.name)
                        if !task_handles[name]
                            orocos_task = orocos_process.task(name)
                            orocos_task.process = orocos_process
                            task_handles[name] =  orocos_task
                        end
                    end

                    each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                        initialize_running_task(task, task_handles[task.orocos_name])
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
                                t.cleanup
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
                    emit :failed
                elsif history.find(&:terminal?)
                    # Do nothing. A terminal event already happened, so we don't
                    # need to tell what kind of end this is for the system
                    emit :stop
                elsif result.success?
                    emit :success
                elsif result.signaled?
                    emit :signaled, result
                else
                    emit :failed, result
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

            # Removes any connection that points to tasks that were in this
            # process, and that are therefore dead because of the process
            # termination
            def cleanup_dead_connections
                return if !task_handles

                # task_handles is only initialized when ready is reached ...
                # so can be nil here
                all_orocos_tasks = task_handles.values.to_set
                all_orocos_tasks.each do |task|
                    task.each_parent_vertex(ActualDataFlow) do |parent_task|
                        if parent_task.process
                            next if !parent_task.process.running?
                            roby_task = Deployment.all_deployments[parent_task.process]
                            next if roby_task.finishing? || roby_task.finished?
                        end

                        mappings = parent_task[task, ActualDataFlow]
                        mappings.each do |(source_port, sink_port), policy|
                            begin
                                parent_task.port(source_port).disconnect_from(task.port(sink_port, false))
                            rescue Exception => e
                                Syskit.warn "error while disconnecting #{parent_task}:#{source_port} from #{task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                            end
                        end
                    end

                    # NOTE: we cannot do the same for child tasks as RTT does
                    # not support selective disconnection over CORBA
                    ActualDataFlow.remove(task)
                    RequiredDataFlow.remove(task)
                end

                if pending = Flows::DataFlow.pending_changes
                    _, _, removed, _ = *pending
                    removed.delete_if { |(source, sink), _| all_orocos_tasks.include?(source) || all_orocos_tasks.include?(sink) }
                end
            end

        end
end


