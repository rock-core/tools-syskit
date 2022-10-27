# frozen_string_literal: true

module Syskit
    module RobyApp
        # A class API-compatible with Runkit::Process that represents tasks that
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
        class UnmanagedProcess < Runkit::ProcessBase
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
            #   defined in {model} to the actual {Runkit::TaskContext}
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

            # Creates a new object managing the tasks that represent a single
            # unmanaged process
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
                @deployed_tasks = {}
                @name_service = process_manager.name_service
                @host_id = host_id
                @quitting = Concurrent::Event.new
                super(name, model)

                @default_logger = false
            end

            # "Starts" this process
            #
            # It spawns a thread that returns once the task got resolved
            #
            # @return [void]
            def spawn(_options = {})
                @spawn_start = Time.now
                @last_warning = Time.now
                @deployed_tasks = {}

                @iors_future = Concurrent::Promises.future do
                    name_service_get_all_tasks
                end
            end

            # Calls the name service until all of the tasks are resolved. Ignores whenever
            # a Runkit::NotFound exception is raised.
            #
            # @raises RuntimeError
            # @raises Runkit::CORBA::ComError
            # @return [Hash<String, Runkit::TaskContext>]
            def name_service_get_all_tasks
                result = {}
                until task_names.size == result.size
                    task_names.each do |name|
                        result[name] = name_service.get(name)
                    rescue Runkit::NotFound
                        next
                    end
                end
                result
            end

            # Verifies that the monitor thread is alive and well, or that the
            # process either terminated or is not spawned yet
            #
            # If the monitor thread terminated unexpectedly, it will raise the
            # exception that terminated it, or a RuntimeError if no exceptions
            # have been raised (which should not be possible)
            def verify_threads_state
                monitor_thread.join if monitor_thread && !monitor_thread.alive?
            end

            # Returns the deployed tasks.The deployed tasks are resolved on wait_running,
            # which is called by `update_deployment_states.rb` when making the deployment
            # ready.
            #
            # @returns [Hash<String, Runkit::TaskContext>]
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

            # Waits until all the tasks are resolved or the timeout is due, registering
            # the IORs of the resolved tasks and starting the monitor.
            #
            # @raises RuntimeError
            # @raises Runkit::CORBA::ComError
            # @return [Hash<String, String>] the ior mappings
            def wait_running(timeout = nil)
                return unless (tasks = @iors_future.value!(timeout))

                @ior_mappings = tasks.transform_values(&:ior)
                @deployed_tasks = tasks
                @monitor_thread = Thread.new { monitor(tasks) }
                @ior_mappings
            end

            # @api private
            #
            # Helper method to kill a thread
            def terminate_and_join_thread(thread)
                return unless thread.alive?

                thread.raise TerminateThread
                begin
                    thread.join
                rescue TerminateThread # rubocop:disable Lint/SuppressedException
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
            # @param [Hash<String, Runkit::TaskContext>] tasks map of task name to task
            # @param [Float] period polling period in seconds
            def monitor(tasks, period: 0.1)
                until quitting?
                    tasks.each_value do |task|
                        task.ping
                    rescue Runkit::ComError
                        return # rubocop:disable Lint/NonLocalExitFromIterator
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
                @iors_future.resolved?
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
