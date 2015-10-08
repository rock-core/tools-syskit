module Syskit
    module RobyApp
        # A class API-compatible with Orocos::Process that represents tasks that
        # are not started by the Syskit instance
        class UnmanagedProcess < Orocos::ProcessBase
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
            def on_localhost?; host_id == 'localhost' end

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

            # @api private
            #
            # The thread that performs the termination of the tasks
            #
            # It is spawned when {#kill} is called
            attr_reader :kill_thread

            # Creates a new object managing the tasks that represent a single unmanaged process
            #
            # @param [nil,#dead_deployment] process_manager the process manager
            #   which created this process. If non-nil, its #dead_deployment method
            #   will be called when {stop} is called
            # @param [String] name the process name
            # @param [OroGen::Spec::Deployment] model the deployment model
            # @param [String] host_id a string identifying the place where the
            #   process is expected to be running
            def initialize(process_manager, name, model, host_id: 'unmanaged_process')
                @process_manager = process_manager
                @deployed_tasks = nil
                @name_service = process_manager.name_service
                @host_id = host_id
                super(name, model)

                @alive = Concurrent::AtomicBoolean.new
            end

            # "Starts" this process
            #
            # It spawns a thread that returns once the task got resolved
            #
            # @return [void]
            def spawn(options = Hash.new)
                @deployed_tasks = nil
                @spawn_thread = Thread.new do
                    spawn_monitor
                end
            end

            # @api private
            #
            # Internal loop for the spawn monitor
            def spawn_monitor
                while @alive.false?
                    begin
                        resolved = model.task_activities.map do |t|
                            [t.name, name_service.get(t.name)]
                        end
                        @alive.make_true
                        return Hash[resolved]
                    rescue Orocos::NotFound, Orocos::ComError
                    end
                    sleep 0.1
                end
            end

            # Waits to have access to the underlying tasks
            #
            # This is a no-op as the tasks get resolved in #spawn
            def wait_running(timeout)
                return if !@spawn_thread.join(timeout)

                @deployed_tasks = @spawn_thread.value
                if !alive?
                    raise RuntimeError, "spawning thread of #{self} quit without setting alive? and without raising an exception"
                end
                @monitor_thread = Thread.new do
                    monitor
                end
                true
            end

            # Verifies that the monitor thread is alive and well, or that the
            # process either terminated or is not spawned yet
            #
            # If the monitor thread terminated unexpectedly, it will raise the
            # exception that terminated it, or a RuntimeError if no exceptions
            # have been raised (which should not be possible)
            def verify_threads_state
                if monitor_thread
                    if !monitor_thread.alive? && alive?
                        begin
                            monitor_thread.value
                        rescue Exception => e
                            raise e, "the monitor thread for #{self} died with: #{e.message}", e.backtrace
                        end
                        raise RuntimeError, "the monitor thread for #{self} died, but not from an exception"
                    end
                end

                if kill_thread
                    if !kill_thread.alive? && alive?
                        begin
                            kill_thread.value
                        rescue Exception => e
                            raise e, "the kill thread for #{self} died with: #{e.message}", e.backtrace
                        end
                        raise RuntimeError, "the kill thread for #{self} died, but not from an exception"
                    end
                end
            end

            # Returns the component object for the given name
            #
            # @raise [RuntimeError] if the process is not running yet
            # @raise [ArgumentError] if the name is not the name of a task on
            #   self
            def task(task_name)
                if !deployed_tasks
                    raise RuntimeError, "process not running yet"
                elsif task = deployed_tasks[task_name]
                    task
                else
                    raise ArgumentError, "#{task_name} is not a task of #{self}"
                end
            end

            def terminate_and_join_thread(thread)
                thread.raise TerminateThread
                begin
                    thread.join
                rescue TerminateThread
                end
            end

            # "Kill" this process
            #
            # It shuts down the tasks that are part of it
            def kill(wait = true)
                if !alive?
                    terminate_and_join_thread(@spawn_thread)
                    @alive.make_false # just to make sure
                    return
                end

                @monitor_thread, monitor_thread = nil, @monitor_thread
                @kill_thread = Thread.new do
                    if monitor_thread
                        terminate_and_join_thread(monitor_thread)
                    end

                    deployed_tasks.each_value do |task|
                        begin
                            if task.rtt_state == :RUNNING
                                task.stop
                            end
                            if task.rtt_state == :STOPPED
                                task.cleanup
                            end
                        rescue Orocos::NotFound
                        end
                    end
                    dead!
                end
                if wait
                    @kill_thread.value
                end
            end

            def monitor(period: 0.1)
                while true
                    deployed_tasks.each_value do |task|
                        begin task.ping
                        rescue Orocos::ComError
                            dead!
                            return
                        end
                    end
                    sleep period
                end
            end

            def dead!
                process_manager.dead_deployment(self)
                @alive.make_false
            end

            # Returns true if the tasks have been successfully discovered
            def ready?; !!deployed_tasks end
            # True if the process is running. This is an alias for running?
            def alive?; @alive.true? end
            # True if the process is running. This is an alias for alive?
            def running?; @alive.true? end

            def join
                raise NotImplementedError, "UnmanagedProcess#join is not implemented"
            end
        end
    end
end

