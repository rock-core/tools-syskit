# frozen_string_literal: true

require "orocos/async"

module Syskit
    module Telemetry
        module Async
            # In-process name service
            #
            # It is exclusively filled based on information that comes from the async
            # {Client}
            class NameService < Orocos::NameServiceBase
                include MainThreadRestrictions

                # A new NameService instance
                #
                # @param [Hash<String,Orocos::TaskContext>] tasks The tasks which are
                #        known by the name service.
                # @note The namespace is always "Local"
                def initialize(
                    discovery_executor:
                        Concurrent::ThreadPoolExecutor.new(max_threads: 10),
                    port_read_manager: PortReadManager.new
                )
                    super()

                    update_main_thread

                    @iors = Concurrent::AtomicReference.new({})
                    @registered_tasks = Concurrent::Hash.new
                    @task_added_callbacks = Concurrent::Array.new
                    @task_removed_callbacks = Concurrent::Array.new
                    @orogen_models = Concurrent::Hash.new
                    @discovery = {}
                    @discovery_executor = discovery_executor
                    @port_read_manager = port_read_manager
                end

                def tasks
                    @registered_tasks.values
                end

                def dispose
                    cleanup
                    @discovery_executor.shutdown
                end

                def names
                    @registered_tasks.keys
                end

                def include?(name)
                    @registered_tasks.key?(name)
                end

                # Asynchronously update the name server given the known set of tasks
                #
                # After this call, any task not in the tasks parameter will have been
                # removed from the name server
                #
                # @param [#ior,#name] list of IOR and name of remote tasks to resolve.
                #   This list is complete, that is it contains all the tasks that the
                #   name server should know about
                # @return [Array<String>] list of task names that are either known, or
                #   that are being discovered
                def async_update_tasks(tasks)
                    ensure_in_main_thread

                    iors = tasks.each_with_object({}) { |t, h| h[t.name] = t.ior }
                    @iors.set(iors)

                    remove_changed_tasks(iors)

                    # Resolve finished futures
                    resolve_discovered_tasks

                    # Then check what tasks need to be discovered, and discover them
                    #
                    # We never spawn two futures to resolve the same name. Instead,
                    # when we get the feature result, we check whether the
                    # IOR has changed, and act accordingly
                    queue_new_tasks_discovery(tasks)
                end

                # @api private
                #
                # Filter a list of tasks, queueing futures to discover the new ones
                #
                # @param [#ior,#name] tasks list of tasks to be discovered
                def queue_new_tasks_discovery(tasks)
                    tasks.each do |t|
                        next if @discovery[t.name]
                        next if t.ior == @registered_tasks[t.name]&.identity

                        async_discover_task(t)
                    end
                end

                # Deregister and dispose of tasks who disappeared or have a
                # different IOR
                def remove_changed_tasks(iors)
                    @registered_tasks.dup.each do |name, task|
                        new_ior = iors[name]
                        deregister(name).dispose if !new_ior || task.identity != new_ior
                    end
                end

                class AsyncDiscoveryError < RuntimeError; end

                AsyncDiscovery = Struct.new(
                    :task, :future, :ior, :async_task, keyword_init: true
                ) do
                    def update_from_result(port_read_manager:)
                        fulfilled, (ior, discovered), reason = future.result
                        unless fulfilled
                            raise AsyncDiscoveryError,
                                  "unexpected error during asynchronous " \
                                  "task discovery: #{reason}"
                        end

                        self.ior = ior
                        return unless discovered

                        self.async_task = TaskContext.from_async_discovery(
                            discovered, port_read_manager: port_read_manager
                        )
                    end

                    def wait
                        future.result
                    end

                    def resolved?
                        future.resolved?
                    end
                end

                # @api private
                #
                # Create a future that discovers a remote task
                def async_discover_task(task)
                    ensure_in_main_thread

                    future = Concurrent::Promises.future_on(@discovery_executor) do
                        ior = @iors.get[task.name]

                        # ior will be nil if the task has been removed from the task
                        # set while the future was pending
                        discover_task(task.name, ior, task.orogen_model_name) if ior
                    end
                    @discovery[task.name] = AsyncDiscovery.new(task: task, future: future)
                end

                def wait_and_resolve_all_pending_discoveries
                    @discovery.each_value { _1.future.wait }
                    resolve_discovered_tasks
                end

                # @api private
                #
                # Process the tasks that have been (asynchronously) discovered
                def resolve_discovered_tasks
                    ensure_in_main_thread

                    while (async_discovery = pop_discovered_task)
                        register(
                            async_discovery.async_task,
                            name: async_discovery.task.name
                        )
                    end
                end

                # Whether some discoveries have been queued but not yet resolved
                def has_pending_discoveries?
                    !@discovery.empty?
                end

                # Wait for all pending discoveries to finish
                def wait_for_task_discovery
                    @discovery.each_value(&:wait)
                end

                # @api private
                #
                # Find a valid resolved task from the pending discoveries
                #
                # @return [AsyncDiscovery,nil] a valid resolved task or nil if there are
                #   none so far
                def pop_discovered_task
                    ensure_in_main_thread

                    loop do
                        return unless (async_discovery = pop_finished_discovery)
                        next unless finished_discovery_validate_ior(async_discovery)
                        next unless async_discovery.async_task # error during resolution

                        return async_discovery
                    end
                end

                # @api private
                #
                # Get one async discovery result from the terminated discovery futures
                #
                # Unlike {pop_discovered_task}, it will not try to find a valid discovered
                # task. It only gets one finished result
                #
                # @return [AsyncDiscovery]
                def pop_finished_discovery
                    ensure_in_main_thread

                    async_discovery = @discovery.each_value.find(&:resolved?)
                    return unless async_discovery

                    @discovery.delete(async_discovery.task.name)
                    async_discovery.update_from_result(
                        port_read_manager: @port_read_manager
                    )
                    async_discovery
                end

                # @api private
                #
                # Validate that an async discovery result matches the expected IOR
                # for the task
                #
                # To guard against race conditions, the name service object maintains
                # a hash of the task names to the expected IORs. When we fetch an async
                # discovery result, we validate that the found task is actually pointing
                # to the expected IOR. If it is not, the result is thrown away and a
                # new discovery is initiated
                #
                # @param [AsyncDiscovery] async_discovery
                def finished_discovery_validate_ior(async_discovery)
                    return unless async_discovery.task

                    current_ior = @iors.get[async_discovery.task.name]
                    return unless current_ior

                    return true if async_discovery.ior == current_ior

                    # The IOR associated with that name changed since the future
                    # started processing. Throw away the resolved task and start
                    # again
                    async_discovery.async_task&.dispose
                    async_discover_task(async_discovery.task)
                    false
                end

                # @api private
                #
                # Discover a single task
                #
                # @param [String] name
                # @param [String] ior
                # @param [String] orogen_model_name
                # @return [(String,(Orocos::Async::TaskContext,nil))] the IOR used to
                #   resolve the task, and the async taskcontext that represents it. The
                #   task is nil if the resolution failed
                def discover_task(name, ior, orogen_model_name)
                    orogen_model = orogen_model_from_name(orogen_model_name)
                    discovered = TaskContext.async_discovery(name, ior, orogen_model)

                    [ior, discovered]
                rescue StandardError => e
                    warn "Failed discovery of task #{name}: #{e.message}"
                    e.backtrace.each do |line|
                        warn "  #{line}"
                    end
                    [ior, nil]
                end

                # Re-create the orogen model from its name
                #
                # @param [String] name
                # @return [OroGen::Spec::TaskContext]
                def orogen_model_from_name(name)
                    @orogen_models[name] ||= Orocos.create_orogen_task_context_model(name)
                end

                # (see NameServiceBase#get)
                def ior(name)
                    task = @registered_tasks[name]
                    if (identity = task&.identity)
                        return identity
                    end

                    raise Orocos::NotFound, "task context #{name} cannot be found."
                end

                # Return a task from its name, or nil if it does not exist
                #
                # @param [String] name
                # @return [TaskContext,nil]
                def find(name)
                    @registered_tasks[name]
                end

                # Return a task from its name, or raise if it does not exist
                #
                # @param [String] name
                # @return [TaskContext]
                # @raise [Orocos::NotFound]
                def get(name, **)
                    task = find(name)
                    return task if task

                    raise Orocos::NotFound, "task context #{name} cannot be found."
                end

                # Registers the given {Orocos::TaskContext} on the name service.
                # If a name is provided, it will be used as an alias. If no name is
                # provided, the name of the task is used. This is true even if the
                # task name is renamed later.
                #
                # @param [Orocos::TaskContext] task The task.
                # @param [String] name Optional name which is used to register the task.
                def register(task, name: task.name)
                    @registered_tasks[name] = task
                    trigger_task_added(name)
                end

                # Deregisters the given name or task from the name service.
                #
                # @param [String,TaskContext] name The name or task
                def deregister(name)
                    task = @registered_tasks.delete(name)
                    trigger_task_removed(name)
                    task
                end

                # (see Base#cleanup)
                def cleanup
                    names = @registered_tasks.keys
                    @registered_tasks.clear
                    @iors.set({})
                    @discovery.clear
                    @orogen_models.clear
                    names.each { trigger_task_removed(_1) }
                end

                def to_async
                    self
                end

                def on_task_added(&block)
                    @task_added_callbacks << block
                    Roby.disposable { @task_added_callbacks.delete(block) }
                end

                def trigger_task_added(name)
                    error = nil
                    @task_added_callbacks.each do |block|
                        block.call(name)
                    rescue RuntimeError => e
                        error = e
                    end

                    raise error if error
                end

                def on_task_removed(&block)
                    @task_removed_callbacks << block
                    Roby.disposable { @task_removed_callbacks.delete(block) }
                end

                def trigger_task_removed(name)
                    error = nil
                    @task_removed_callbacks.each do |block|
                        block.call(name)
                    rescue RuntimeError => e
                        error = e
                    end

                    raise error if error
                end
            end
        end
    end
end
