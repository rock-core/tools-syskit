# frozen_string_literal: true

module Syskit
    module RobyApp
        module RubyTasks
            # Representation and management of a set of ruby tasks
            #
            # This provides a {Orocos::Process}-compatible API to ruby tasks. It allows
            # to define tasks in an oroGen deployment model and "spawn" them all at
            # once, as well as dispose of them all at once.
            class Process < Orocos::ProcessBase
                # The Ruby process server that spawned this process
                #
                # If non-nil, the object's #dead_deployment will be called when self is
                # stopped
                #
                # @return [#dead_deployment,nil]
                attr_reader :ruby_process_server

                # The set of deployed tasks
                #
                # @return [{String=>TaskContext}] mapping from the deployed task name as
                #   defined in {model} to the actual ruby task object
                attr_reader :deployed_tasks

                # The host on which this process' tasks run
                #
                # This is always 'localhost' as ruby tasks are instanciated inside the
                # ruby process
                #
                # @return [String]
                def host_id
                    "localhost"
                end

                # Whether the tasks in this process are running on the same machine than
                # the ruby process
                #
                # This is always true as ruby tasks are instanciated inside the ruby
                # process
                #
                # @return [Boolean]
                def on_localhost?
                    true
                end

                # The PID of the process in which the tasks run
                #
                # This is always Process.pid as ruby tasks are instanciated inside the
                # ruby
                # process
                #
                # @return [Integer]
                def pid
                    ::Process.pid
                end

                # The task context class that should be used on the client side
                #
                # Defaults to {TaskContext}, another option is {StubTaskContext}
                #
                # @return [Class]
                attr_reader :task_context_class

                # The ior mappings of the deployed tasks
                attr_reader :ior_mappings

                # Creates a new ruby task process
                #
                # @param [nil,#dead_deployment] ruby_process_server the process manager
                #   which creates this process. If non-nil, its #dead_deployment method
                #   will be called when this process stops
                # @param [String] name the process name
                # @param [OroGen::Spec::Deployment] model the deployment model
                def initialize(
                    ruby_process_server, name, model,
                    task_context_class: Orocos::RubyTasks::TaskContext
                )
                    @ruby_process_server = ruby_process_server
                    @deployed_tasks = {}
                    @task_context_class = task_context_class
                    @ior_mappings = nil
                    super(name, model)
                end

                # Deploys the tasks defined in {model} as ruby tasks
                #
                # @return [void]
                def spawn(register_on_name_server: true, **_options)
                    model.task_activities.each do |deployed_task|
                        name = get_mapped_name(deployed_task.name)
                        Orocos.allow_blocking_calls do
                            deployed_tasks[name] =
                                task_context_class.from_orogen_model(
                                    name, deployed_task.task_model,
                                    register_on_name_server: register_on_name_server
                                )
                        end
                    end
                    @alive = true
                end

                # The ruby tasks are already ready, so all this is does is to get the IOR
                # mappings from them. The wait_running method name is maintained to keep
                # the API closer to the remote process'.
                def wait_running
                    unless @ior_mappings
                        (@ior_mappings = deployed_tasks.transform_values(&:ior))
                    end
                    @ior_mappings
                end

                def task(task_name)
                    if (t = deployed_tasks[task_name])
                        t
                    else
                        raise ArgumentError,
                              "#{self} has no task called #{task_name}, known tasks: "\
                              "#{deployed_tasks.keys.sort.join(', ')}"
                    end
                end

                def resolve_all_tasks
                    deployed_tasks
                end

                def define_ior_mappings(ior_mappings)
                    @ior_mappings = ior_mappings
                end

                def kill(
                    _wait = true, status = ProcessManager::Status.new(exit_code: 0), **
                )
                    deployed_tasks.each_value(&:dispose)
                    dead!(status)
                end

                def dead!(status = ProcessManager::Status.new(exit_code: 0))
                    @alive = false
                    ruby_process_server&.dead_deployment(name, status)
                end

                def join
                    raise NotImplementedError, "RemoteProcess#join is not implemented"
                end

                # True if the process is running. This is an alias for running?
                def alive?
                    @alive
                end

                # True if the process is running. This is an alias for alive?
                def running?
                    @alive
                end
            end
        end
    end
end
