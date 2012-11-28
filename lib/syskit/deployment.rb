# The module in which all deployment models are defined
module Deployments
end

module Syskit
        class << self
            # The set of known process servers.
            #
            # It maps the server name to the Orocos::ProcessServer instance
            attr_reader :process_servers
        end
        @process_servers = Hash.new

        # In oroGen, a deployment is a Unix process that holds a certain number
        # of task contexts. This Roby task represents the unix process itself.
        # Once it gets instanciated, the associated task contexts can be
        # accessed with #task(name)
        class Deployment < ::Roby::Task
            extend Models::Deployment

            def initialize(arguments = Hash.new)
	    	opts, task_arguments = Kernel.filter_options  arguments, :log => true
		task_arguments[:log] = opts[:log]
                @logged_ports = Set.new
                super(task_arguments)
	    end

            @@all_deployments = Hash.new


            # The PID of this process
            def pid
                @pid ||= orocos_process.pid
            end

            # A name => Orocos::TaskContext instance mapping of all the task
            # contexts running on this deployment
            attr_reader :task_handles

            # The underlying Orocos::Process instance
            attr_reader :orocos_process

            # The set of ports for which logging has already been set up, as a
            # set of [task_name, port_name] pairs
            attr_reader :logged_ports

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

            # Returns true if +self+ and +task+ are running on the same process
            # server
            def on_same_server?(task)
                task == self || machine == task.machine
            end

            def instanciate_all_tasks
                model.each_orogen_deployed_task_context_model.map do |act|
                    task(act.name)
                end
            end

            # The list of deployed task contexts for this particular deployment
            #
            # It takes into account deployment prefix
            def each_orogen_deployed_task_context_model(&block)
                model.each_orogen_deployed_task_context_model(&block)
            end

            # The unique name for this particular deployment instance
            #
            # It takes into account deployment prefix
            #
            # @return [String]
            def deployment_name
                model.deployment_name
            end

            # Returns an task instance that represents the given task in this
            # deployment.
            def task(name, model = nil)
                activity = each_orogen_deployed_task_context_model.
                    find { |act| name == act.name }
                if !activity
                    raise ArgumentError, "no task called #{name} in #{self.class.deployment_name}"
                end

                activity_model = TaskContext.model_for(activity.context)
                if model
                    if !(model <= activity_model)
                        raise ArgumentError, "incompatible explicit selection #{model} for the model of #{name} in #{self}"
                    end
                else
                    model = activity_model
                end
                plan.add(task = model.new(:orocos_name => activity.name))
                task.executed_by self
                task.orogen_model = activity
                if ready?
                    initialize_running_task(name, task)
                end
                task
            end

            # Internal helper to set the #orocos_task
            def initialize_running_task(name, task)
                task.orocos_task = task_handles[name]
                task.orocos_task.process = orocos_process
                if Conf.orocos.conf_log_enabled?
                    task.orocos_task.log_all_configuration(Orocos.configuration_log)
                end
                # Override the base model with the new one. The new model
                # may have been specialized, for instance to handle dynamic
                # slave creation
                # task.orogen_task.instance_variable_set(:@model, task.model.orogen_deployment_model)
            end

            ##
            # method: start!
            #
            # Starts the process and emits the start event immediately. The
            # :ready event will be emitted when the deployment is up and
            # running.
            event :start do |context|
                host = self.arguments['on'] ||= 'localhost'
                Syskit.info { "starting deployment #{model.deployment_name} on #{host}" }

                process_server, log_dir = Syskit.process_servers[host]
                if !process_server
                    raise ArgumentError, "cannot find the process server for #{host}"
                end
                options = Hash.new

                # Checking for options which apply in a multi-robot context,
                # e.g. such as prefixing and service_discovery (distributed
                # nameservice
                #
                # multirobot:
                #     use_prefixing: true
                #     exclude_from_prefixing:
                #         - SIMULATION
                #         - .*TEST.*
                #     service_discovery:
                #         - domain: _rimres._tcp
                #         - publish:
                #             - .*CORE.*
                if multirobot = Roby.app.options["multirobot"]
                    # Use prefixing of components in order to allow
                    # multiple robots to use the same set of deployments,
                    # since tasks will be renamed using th given prefix
                    # (robot_name)
                    # e.g. with prefix enabled:
                    #     ./scripts/run robot_0 robottype
                    # the prefix 'robot_0_' will be used
                    if multirobot.key?("use_prefixing")

                        exclude = false
                        # Exclude deployments from prefixing that match one of the given
                        # regular expressions (matching on complete deployment_name)
                        if prefix_black_list = multirobot["exclude_from_prefixing"]
                            prefix_black_list.each do |pattern|
                                begin
                                    exclude = exclude || deployment_name =~ Regexp.new('^' + pattern + '$')
                                rescue RegexpError => e
                                    Robot.error "Regular expression in configuration of multirobot with errors: #{e}"
                                end
                            end
                        end
                        if !exclude
                            Robot.info "Deployment #{deployment_name} is started with prefix #{Roby.app.robot_name}"
                            args = { :prefix => "#{Roby.app.robot_name}_" }
                            options.merge!(args)
                        else
                            Robot.info "Deployment #{deployment_name} is started without prefix #{Roby.app.robot_name}"
                        end

                    end
                    # Check whether the deployment should be started with
                    # service discovery options, in order to be published within
                    # the distributed nameservice
                    if multirobot.key?("service_discovery")
                        service_discovery = multirobot['service_discovery']
                        sd_domains = service_discovery["domain"]
                        publish = false
			if publish_white_list = service_discovery['publish']
                            publish_white_list.each do |pattern|
                                begin
                                    publish = publish || deployment_name =~ Regexp.new('^' + pattern + '$')
                                rescue RegexpError => e
                                    Robot.error "Regular expression in configuration of multirobot with errors: #{e}"
                                end
                            end
			end
			if publish
                            args = { 'sd-domain' => sd_domains }
                            options.merge!(args)
                        end
                    end
                end
                @orocos_process = process_server.start(model.deployment_name, 
                                                          :working_directory => log_dir, 
                                                          :output => "%m-%p.txt", 
                                                          :wait => false,
                                                          :cmdline_args => options)

                Deployment.all_deployments[@orocos_process] = self
                emit :start
            end

            def log_dir
                host = self.arguments['on'] ||= 'localhost'
                process_server, log_dir = Syskit.process_servers[host]
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
                model.each_deployed_task_context do |act|
                    TaskContext.configured.delete(act.name)
                end
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orocos_task = nil
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
                                    Syskit.warn "error while disconnecting #{parent_task}:#{source_port} from #{task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
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
                                Syskit.warn "error while disconnecting #{task}:#{source_port} from #{child_task}:#{sink_port} after #{task} died (#{e.message}). Assuming that both tasks are already dead."
                            end
                        end
                    end

                    ActualDataFlow.remove(task)
                    RequiredDataFlow.remove(task)
                end
            end

            # Returns true if the orocos/roby plugin configuration requires
            # +port+ to be logged
            def log_port?(port)
                result = !Roby::State.orocos.port_excluded_from_log?(self,
                        TaskContext.model_for(port.task), port)

                if !result
                    Robot.info "not logging #{port.task.name}:#{port.name}"
                end
                result
            end

            poll do
                next if ready?

                if orocos_process.wait_running(0)
                    emit :ready

                    @task_handles = Hash.new
                    model.each_deployed_task_context do |activity|
                        name = orocos_process.get_mapped_name(activity.name)
                        task_handles[activity.name] =  
                          ::Orocos::TaskContext.get(name)
                    end

                    each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                        initialize_running_task(task.orocos_name, task)
                    end
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
                begin
                    if task_handles
                        task_handles.each_value do |t|
                            if t.rtt_state == :STOPPED
                                t.cleanup
                            end
                        end
                    end
                    ready_to_die!
                    orocos_process.kill(false)
                rescue CORBA::ComError
                    # Assume that the process is killed as it is not reachable
                end
            end
        end
end


