# frozen_string_literal: true

module Syskit
    module ProcessManagers
        module InProcess
            # Representation of a single running in-process deployment
            class Process < ProcessBase
                extend Logger::Hierarchy
                include Logger::Hierarchy

                # The {Manager} which created this process
                #
                # If non-nil, the object's #dead_deployment will be called when self
                # is stopped
                #
                # @return [#dead_deployment,nil]
                attr_reader :manager

                # The set of deployed tasks
                #
                # @return [{String=>TaskContext}] mapping from the deployed task name as
                #   defined in {model} to the actual {Orocos::TaskContext}
                attr_reader :deployed_tasks

                # The host on which this process' tasks run.
                #
                # @return [String]
                attr_reader :host_id

                # Whether the tasks in this process are running on the same machine than
                # the ruby process
                #
                # This is always true as ruby tasks are instanciated inside the ruby
                # process
                #
                # @return [Boolean]
                def on_localhost?
                    host_id == "localhost"
                end

                # The PID of the process in which the tasks run
                #
                # This is always Process.pid as in-process tasks are instanciated inside
                # the ruby process
                #
                # @return [Integer]
                attr_reader :pid

                # @api private
                #
                # The thread that monitors the tasks availability
                #
                # It is spawned the first time {#wait_running} returns true
                attr_reader :monitor_thread

                # Creates a new object managing tasks that are running in-process
                #
                # @param [nil,#dead_deployment] process_manager the process manager
                #   which created this process. If non-nil, its #dead_deployment method
                #   will be called when {stop} is called
                # @param [String] name the process name
                # @param [OroGen::Spec::Deployment] model the deployment model
                def initialize(manager, name, model, host_id: "localhost")
                    @manager = manager
                    @host_id = host_id
                    super(name, model)

                    @component_loader = Roby.app.syskit_component_loader
                    @default_logger = false
                end

                # "Starts" this process
                #
                # It actually instanciates the underlying task
                #
                # @return [void]
                def spawn(_options = {})
                    @deployed_tasks =
                        model.each_task.each_with_object({}) do |deployed, h|
                            mapped_name = mapped_name_of(deployed.name)
                            h[mapped_name] = spawn_deployed_task(mapped_name, deployed)
                        end
                    @killed = false
                end

                # Module used to extend Orocos::TaskContext for in-process tasks
                module InProcessTask
                    # The local task handle, used to dispose of the local task when done
                    #
                    # @return [Orocos::LocalTask]
                    attr_reader :local_task

                    def dispose
                        local_task.dispose
                    end

                    def execute
                        local_task.execute
                    end
                end

                def spawn_deployed_task(mapped_name, orogen_deployed_task)
                    @component_loader.load_task_library(
                        orogen_deployed_task.task_model.project.name
                    )

                    task_model = orogen_deployed_task.task_model
                    local_task = @component_loader.create_local_task_context(
                        mapped_name, task_model.name, false
                    )
                    local_task_activity_setup(local_task, orogen_deployed_task)

                    task = Orocos.allow_blocking_calls do
                        Orocos::TaskContext.new(
                            local_task.ior, name: mapped_name, model: task_model
                        )
                    end

                    task.extend InProcessTask
                    # protect the local task against GC
                    task.instance_variable_set :@local_task, local_task
                    task
                end

                def local_task_activity_setup(local_task, orogen_deployed_task)
                    if orogen_deployed_task.triggered?
                        local_task.make_triggered
                    elsif orogen_deployed_task.periodic?
                        local_task.make_periodic(orogen_deployed_task.period)
                    elsif orogen_deployed_task.fd_driven?
                        local_task.make_fd_driven
                    elsif orogen_deployed_task.slave?
                        local_task.make_slave
                    else
                        activity_name = orogen_deployed_task.activity_type.name
                        raise ArgumentError, "unsupported activity #{activity_name}"
                    end
                end

                # Returns the deployed tasks.The deployed tasks are resolved on
                # wait_running, which is called by `update_deployment_states.rb`
                # when making the deployment ready.
                #
                # @returns [Hash<String, Orocos::TaskContext>]
                def resolve_all_tasks
                    @deployed_tasks
                end

                def define_ior_mappings(ior_mappings)
                    @ior_mappings = ior_mappings
                end

                # Returns the component object for the given name
                #
                # @raise [RuntimeError] if the process is not running yet
                # @raise [ArgumentError] if the name is not the name of a task on
                #   self
                def task(task_name)
                    raise "process not running yet" unless ready?

                    @deployed_tasks.fetch(task_name)
                end

                # Waits until all the tasks are resolved or the timeout is due,
                # registering the IORs of the resolved tasks and starting the monitor.
                #
                # @raises RuntimeError
                # @raises Orocos::CORBA::ComError
                # @return [Hash<String, String>] the ior mappings
                def wait_running(_timeout = nil)
                    @deployed_tasks.each_value.map(&:ior)
                end

                # "Kill" this process
                #
                # It shuts down the tasks that are part of it
                def kill(_wait = false, **)
                    @deployed_tasks.each_value(&:dispose)
                    @deployed_tasks = {}
                    @killed = true
                end

                # Returns true if the process died
                def dead?
                    @killed
                end

                # Returns true if the tasks have been successfully discovered
                def ready?
                    true
                end

                # True if the process is running. This is an alias for running?
                def alive?
                    !dead?
                end

                # True if the process is running. This is an alias for alive?
                def running?
                    alive?
                end

                def join
                    raise NotImplementedError, "UnmanagedProcess#join is not implemented"
                end
            end
        end
    end
end
