# frozen_string_literal: true

require "orocos/process"

module Syskit
    module RobyApp
        module RemoteProcesses
            # Representation of a remote process started with ProcessClient#start
            class Process < Orocos::ProcessBase
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

                # Returns the task context object for the process' task that has this
                # name
                def task(task_name)
                    process_client.name_service.get(task_name, process: self)
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

                # Resolve all tasks within the deployment
                #
                # A deployment is usually considered ready when all its tasks can be
                # resolved successfully
                def resolve_all_tasks(cache = {})
                    Orocos::Process.resolve_all_tasks(self, cache) do |task_name|
                        task(task_name)
                    end
                end

                # Waits for the deployment to be ready. +timeout+ is the number of
                # milliseconds we should wait. If it is nil, will wait indefinitely
                def wait_running(timeout = nil)
                    Orocos::Process.wait_running(self, timeout)
                end
            end
        end
    end
end
