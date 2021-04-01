# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class Async
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The target plan
            attr_reader :plan

            # The {Roby::DRoby::EventLogger} used to log timings
            attr_reader :event_logger

            # The thread pool (or, really, any of Concurrent executor)
            attr_reader :thread_pool

            # The future that does the async work
            #
            # It is created by {#start}
            #
            # @return [Resolution]
            attr_reader :future

            def initialize(plan, event_logger: plan.event_logger,
                thread_pool: Concurrent::CachedThreadPool.new)
                @plan = plan
                @event_logger = event_logger
                @thread_pool = thread_pool
                @apply_system_network_options = {}
            end

            def transaction_finalized?
                future.engine.work_plan.finalized?
            end

            def transaction_committed?
                future.engine.work_plan.committed?
            end

            # @api private
            class Resolution < Concurrent::Future
                attr_reader :plan
                attr_reader :requirement_tasks
                attr_reader :engine

                def initialize(plan, event_logger, requirement_tasks, **options, &block)
                    @plan = plan
                    @requirement_tasks = requirement_tasks.to_set
                    @engine = Engine.new(plan, event_logger: event_logger)
                    super(**options, &block)
                end
            end

            ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK = %I[
                compute_deployments garbage_collect validate_final_network
            ].freeze

            def prepare(requirement_tasks = default_requirement_tasks, **resolver_options)
                if @future
                    raise InvalidState,
                          "calling Async#prepare while a generation is in progress"
                end

                @apply_system_network_options = resolver_options.slice(
                    *ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK
                )

                # Resolver is used within the block ... don't assign directly to @future
                resolver = Resolution.new(plan, event_logger, requirement_tasks,
                                          executor: thread_pool) do
                    Thread.current.name = "syskit-async-resolution"
                    log_timepoint_group "syskit-async-resolution" do
                        resolver.engine.resolve_system_network(
                            requirement_tasks, **resolver_options
                        )
                    end
                end
                @future = resolver
            end

            def default_requirement_tasks
                Engine.discover_requirement_tasks_from_plan(plan)
            end

            def start(requirement_tasks = default_requirement_tasks, **resolver_options)
                resolver = prepare(requirement_tasks, **resolver_options)
                resolver.execute
                resolver
            end

            def valid?(current = default_requirement_tasks)
                current.to_set == future.requirement_tasks
            end

            def cancel
                @cancelled = true
                future.cancel
            end

            def finished?
                future.complete?
            end

            def complete?
                future.complete?
            end

            def join
                result = future.value
                raise future.reason if future.rejected?

                result
            end

            def cancelled?
                @cancelled
            end

            class InvalidState < RuntimeError; end

            # Apply the result of the generation
            #
            # @return [Boolean] true if the result has been applied, and false
            #   if the generation was cancelled
            def apply
                unless future.complete?
                    raise InvalidState,
                          "attempting to call Async#apply while processing "\
                          "is in progress"
                end

                engine = future.engine
                if @cancelled
                    engine.discard_work_plan
                    false
                elsif future.fulfilled?
                    required_instances = future.value
                    begin
                        engine.apply_system_network_to_plan(
                            required_instances, **@apply_system_network_options
                        )
                        true
                    rescue ::Exception => e
                        engine.handle_resolution_exception(e, on_error: Engine.on_error)
                        raise e
                    end
                else
                    engine.handle_resolution_exception(
                        future.reason, on_error: Engine.on_error
                    )
                    raise future.reason
                end
            end
        end
    end
end
