# frozen_string_literal: true

module Syskit
    module ProcessManagers
        module Remote
            # Representation of a remote process started with {Manager}
            class Process < ProcessBase
                extend Logger::Hierarchy
                extend Logger::Forward

                # The ProcessClient instance that gives us access to the remote process
                # server
                attr_reader :process_client
                # A string describing the host. It can be used to check if two processes
                # are running on the same host
                def host_id
                    process_client.host_id
                end

                # True if this process is located on the same machine than the ruby
                # interpreter
                def on_localhost?
                    process_client.host == "localhost"
                end

                # The process ID of this process on the machine of the process server
                attr_reader :pid

                def initialize(name, deployment_model, process_client, pid)
                    @process_client = process_client
                    @pid = pid
                    @alive = true
                    @ior_mappings = {}

                    super(name, deployment_model)
                end

                # Retunging the Process name of the remote process
                def process
                    self
                end

                # Called to announce that this process has quit
                def dead!
                    @alive = false
                end

                # Cleanly stop the process
                #
                # @see kill!
                def kill(wait = true, cleanup: true, hard: false)
                    process_client.stop(name, wait, cleanup: cleanup, hard: hard)
                end

                # Wait for the
                def join
                    process_client.join(name)
                end

                # True if the process is running. This is an alias for running?
                def alive?
                    @alive
                end

                # True if the process is running. This is an alias for alive?
                def running?
                    @alive
                end

                def resolve_all_tasks
                    model.task_activities.each_with_object({}) do |deployed_task, map|
                        mapped_name = mapped_name_of(deployed_task.name)
                        unless (ior = @ior_mappings[mapped_name])
                            raise Orocos::IORNotRegisteredError,
                                  "no IOR is registered for #{task_name}"
                        end

                        map[mapped_name] =
                            Orocos::TaskContext.new(
                                ior, name: mapped_name,
                                     model: deployed_task.task_model,
                                     process: self
                            )
                    end
                end

                # no-op, only here to please Orocos::TaskContext
                def register_task(task); end

                def define_ior_mappings(mappings)
                    @ior_mappings = mappings
                end
            end
        end
    end
end
