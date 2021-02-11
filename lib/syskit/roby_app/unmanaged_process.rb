# frozen_string_literal: true

module Syskit
    module RobyApp
        # A class API-compatible with Orocos::Process that represents tasks that
        # are not started by the Syskit instance
        #
        # An UnmanagedProcess can basically be in three states, which are
        # reflected by three threads
        #
        # {#monitor_thread} is started when all tasks have been resolved in
        # {#resolve_all_tasks}. It verifies that the tasks are still reachable.
        # The thread returns when it is not the case.
        #
        # Whether the process is stil in a good state or not should be tested
        # with {#dead?}. {#verify_threads_state} verifies that the threads
        # themselves did not terminate with an exception (and throw the
        # exception).
        class UnmanagedProcess < Orocos::ProcessBase
            extend Logger::Hierarchy
            include Logger::Hierarchy

            class TerminateThread < RuntimeError; end

            # The {UnmanagedTasksManager} object which created this
            #
            # If non-nil, the object's #dead_deployment will be called when self
            # is stopped
            #
            # @return [#dead_deployment,nil]
            attr_reader :process_manager

            # The set of deployed tasks
            #
            # @return [{String=>TaskContext}] mapping from the deployed task name as
            #   defined in {model} to the actual {Orocos::TaskContext}
            attr_reader :deployed_tasks

            # The host on which this process' tasks run
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
            # This is always Process.pid as ruby tasks are instanciated inside the ruby
            # process
            #
            # @return [Integer]
            attr_reader :pid

            # The name service object which should be used to resolve the tasks
            attr_reader :name_service

            # @api private
            #
            # The thread that monitors the tasks availability
            #
            # It is spawned the first time {#wait_running} returns true
            attr_reader :monitor_thread

            # Creates a new object managing the tasks that represent a single unmanaged process
            #
            # @param [nil,#dead_deployment] process_manager the process manager
            #   which created this process. If non-nil, its #dead_deployment method
            #   will be called when {stop} is called
            # @param [String] name the process name
            # @param [OroGen::Spec::Deployment] model the deployment model
            # @param [String] host_id a string identifying the place where the
            #   process is expected to be running
            def initialize(process_manager, name, model, host_id: "unmanaged_process")
                @process_manager = process_manager
                @deployed_tasks = nil
                @name_service = process_manager.name_service
                @host_id = host_id
                @quitting = Concurrent::Event.new
                super(name, model)
            end

            # "Starts" this process
            #
            # It spawns a thread that returns once the task got resolved
            #
            # @return [void]
            def spawn(options = {})
                @spawn_start = Time.now
                @last_warning = Time.now
                @deployed_tasks = nil
            end

            # Verifies that the monitor thread is alive and well, or that the
            # process either terminated or is not spawned yet
            #
            # If the monitor thread terminated unexpectedly, it will raise the
            # exception that terminated it, or a RuntimeError if no exceptions
            # have been raised (which should not be possible)
            def verify_threads_state
                if monitor_thread && !monitor_thread.alive?
                    monitor_thread.join
                end
            end

            def resolve_all_tasks(cache = {})
                resolved = model.task_activities.map do |t|
                    [t.name, (cache[t.name] ||= name_service.get(t.name))]
                end
                @deployed_tasks = Hash[resolved]
                @monitor_thread = Thread.new do
                    monitor
                end
                @deployed_tasks
            rescue Orocos::NotFound, Orocos::ComError => e
                if Time.now - @last_warning > 5
                    Syskit.warn "waiting for unmanaged task: #{e}"
                    @last_warning = Time.now
                end
                nil
            end

            # Returns the component object for the given name
            #
            # @raise [RuntimeError] if the process is not running yet
            # @raise [ArgumentError] if the name is not the name of a task on
            #   self
            def task(task_name)
                if !deployed_tasks
                    raise "process not running yet"
                elsif task = deployed_tasks[task_name]
                    task
                else
                    raise ArgumentError, "#{task_name} is not a task of #{self}"
                end
            end

            # @api private
            #
            # Helper method to kill a thread
            def terminate_and_join_thread(thread)
                return unless thread.alive?

                thread.raise TerminateThread
                begin
                    thread.join
                rescue TerminateThread
                end
            end

            # "Kill" this process
            #
            # It shuts down the tasks that are part of it
            def kill(_wait = false, **)
                # Announce we're quitting to #monitor_thread. It's used in
                # #dead? directly if there is no monitoring thread
                @quitting.set
            end

            # @api private
            #
            # Implementation of the monitor thread, i.e. the thread that will
            # detect if the deployment disappears
            #
            # @param [Float] period polling period in seconds
            def monitor(period: 0.1)
                until quitting?
                    deployed_tasks.each_value do |task|
                        begin task.ping
                        rescue Orocos::ComError
                            return # rubocop:disable Lint/NonLocalExitFromIterator
                        end
                    end
                    sleep period
                end
            end

            # Whether {#kill} requested for {#monitor_thread} to quit
            def quitting?
                @quitting.set?
            end

            # Returns true if the process died
            def dead?
                if monitor_thread
                    !monitor_thread.alive?
                else quitting?
                end
            end

            # Returns true if the tasks have been successfully discovered
            def ready?
                !!deployed_tasks
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
