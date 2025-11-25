# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class AsyncThreaded < Async
            # The thread pool (or, really, any of Concurrent executor)
            attr_reader :thread_pool

            # Object that is passed to the network generation process to handle
            # cancellations and yield
            class Control < Async::Control
                # @param [Concurrent::Event] cancelled whether the resolution
                #   has been cancelled or not
                def initialize(cancelled)
                    super()

                    @cancelled = cancelled
                end

                # (see Async::Control#interruption_point)
                def interruption_point(event_logger, name, **)
                    super

                    !@cancelled.set?
                end
            end

            def initialize(
                plan, requirement_tasks,
                event_logger: plan.event_logger, resolver_options: {}
            )
                @cancelled = Concurrent::Event.new
                super(
                    plan, requirement_tasks,
                    resolution_control: Control.new(@cancelled),
                    event_logger: event_logger, resolver_options: resolver_options
                )

                @thread_pool = Concurrent::CachedThreadPool.new

                create_keepalive_transaction(plan)

                log_timepoint("syskit-netgen:async-threaded-start")

                # Resolver is used within the block ... don't assign directly to @future
                @future = Concurrent::Future.new(executor: thread_pool) do
                    Thread.current.name = "syskit-network-generation"
                    log_timepoint_group "syskit-netgen:gen" do
                        catch(:syskit_netgen_cancelled) do
                            @engine.resolve_system_network(
                                requirement_tasks, **resolver_options
                            )
                        end
                    end
                end
            end

            # Include all components from the plan in a transaction to protect them
            # from GC while we deploy
            #
            # This is to make sure we don't tear down, during network generation,
            # subparts of the old network that are actually needed by the new network.
            def create_keepalive_transaction(plan)
                @keepalive = Roby::Transaction.new(plan)
                plan.find_local_tasks(Component).each do |component_task|
                    @keepalive.wrap(component_task) unless component_task.finished?
                end
            end

            def start
                @future.execute
            end

            def self.start(
                plan, requirement_tasks = default_requirement_tasks, resolver_options: {}
            )
                async = new(plan, requirement_tasks, resolver_options: resolver_options)
                async.start
                async
            end

            # Cancel this resolution
            #
            # This is only signalling that the resolution should be cancelled. The
            # cancellation itself might take some time
            def cancel
                @cancelled.set
            end

            # Whether this resolution has been cancelled
            def cancelled?
                @cancelled.set?
            end

            def finished?
                @finished
            end

            attr_reader :result

            # Periodic polling of the resolution process
            #
            # @param [nil,Set<InstanceRequirementTask>] requirement_tasks the requirements
            #   that currently need to be resolved. The class will cancel the current
            #   resolution if it does not match the set it is actually resolving. Pass
            #   nil to ignore the test altogether
            def poll(requirement_tasks)
                return if finished?

                cancel if !cancelled? && requirement_tasks && !valid?(requirement_tasks)

                return unless network_generation_complete?

                success = catch(:syskit_netgen_cancelled) do
                    @result = finalize
                    true
                end
                @engine.discard_work_plan unless success
            end

            def apply_network_generation
                unless network_generation_complete?
                    raise InvalidState,
                          "attempting to call Async#apply_network_generation while " \
                          "processing is in progress"
                end

                super(result: network_generation_result, error: network_generation_error)
            end

            def finalize
                running_requirement_tasks = @requirement_tasks.find_all(&:running?)

                result = log_timepoint_group("syskit-netgen:apply") do
                    apply_network_generation
                end
                update_instance_requirement_tasks_on_result(result)
                result
            rescue Exception => e # rubocop:disable Lint/RescueException
                raise unless running_requirement_tasks

                update_instance_requirement_tasks_on_exception(
                    running_requirement_tasks, e
                )
            ensure
                finished!
            end

            def finished!
                @finished = true
                # Transactions may be discarded externally on e.g. plan teardown
                @keepalive.discard_transaction unless @keepalive.finalized?
                @thread_pool.shutdown
                log_timepoint("syskit-netgen:async-threaded-finished")
            end

            def network_generation_result
                @future.value
            end

            def network_generation_error
                @future.reason
            end

            def network_generation_complete?
                @future.complete?
            end

            def network_generation_join
                @future.value
            end

            # Wait for the resolution to finish and either apply the result or raise if
            # there is an error
            def join(raise_on_error: true)
                @future.value

                begin
                    raise @future.reason if @future.rejected? && raise_on_error
                rescue Concurrent::CancelledOperationError
                    return
                end

                poll(@requirement_tasks)
            end
        end
    end
end
