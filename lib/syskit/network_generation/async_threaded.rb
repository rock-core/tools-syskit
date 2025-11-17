# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class AsyncThreaded < Async
            # The thread pool (or, really, any of Concurrent executor)
            attr_reader :thread_pool

            def initialize(
                plan, requirement_tasks,
                event_logger: plan.event_logger, **resolver_options
            )
                super

                @thread_pool = Concurrent::CachedThreadPool.new

                # Protect all Component instances against garbage collection
                # by adding them in a transaction. This is to make sure we don't
                # tear down, during network generation, subparts of the old network
                # that are actually needed by the new network.
                @keepalive = Roby::Transaction.new(plan)
                plan.find_local_tasks(Component).each do |component_task|
                    @keepalive.wrap(component_task) unless component_task.finished?
                end

                # Resolver is used within the block ... don't assign directly to @future
                @future = Concurrent::Future.new(executor: thread_pool) do
                    Thread.current.name = "syskit-network-generation"
                    log_timepoint_group "syskit-network-generation" do
                        @engine.resolve_system_network(
                            requirement_tasks, **resolver_options
                        )
                    end
                end
            end

            def start
                @future.execute
            end

            def self.start(
                plan, requirement_tasks = default_requirement_tasks, **resolver_options
            )
                async = new(plan, requirement_tasks, **resolver_options)
                async.start
                async
            end

            def finished?
                @finished
            end

            def poll(requirement_tasks)
                return if finished?

                cancel if !cancelled? && !valid?(requirement_tasks)

                return unless network_generation_complete?

                apply_complete_network_generation
            end

            def apply_complete_network_generation
                running_requirement_tasks = @requirement_tasks.find_all(&:running?)

                return unless (result = apply_network_generation)

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
                @keepalive.discard_transaction
                @thread_pool.shutdown
            end

            def cancel
                super

                @future.cancel
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

            def network_generation_successful?
                @future.fulfilled?
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
