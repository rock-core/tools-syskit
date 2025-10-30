# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class AsyncFiber
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The target plan
            attr_reader :plan

            # The {Roby::DRoby::EventLogger} used to log timings
            attr_reader :event_logger

            def initialize(plan, event_logger: plan.event_logger)
                @plan = plan
                @event_logger = event_logger
                @apply_system_network_options = {}
            end

            def transaction_finalized?
                @engine.work_plan.finalized?
            end

            def transaction_committed?
                @engine.work_plan.committed?
            end

            # @api private
            class Resolution < Fiber
                attr_reader :plan, :requirement_tasks, :engine, :reason, :value

                def initialize(plan, event_logger, requirement_tasks, **options)
                    @plan = plan
                    @requirement_tasks = requirement_tasks.to_set
                    @engine = Engine.new(plan, fiber: true, event_logger: event_logger)
                    super(**options) do
                        @value = yield
                    rescue Exception => e
                        @reason = e
                    end
                end

                def finished?
                    @alive
                end

                def complete?
                    !@reason
                end

                def rejected?
                    @reason
                end
            end

            ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK = %I[
                compute_deployments garbage_collect validate_final_network
            ].freeze

            def prepare(requirement_tasks = default_requirement_tasks, **resolver_options)
                if @fiber
                    raise InvalidState,
                          "calling Async#prepare while a generation is in progress"
                end

                @apply_system_network_options = resolver_options.slice(
                    *ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK
                )

                # Resolver is used within the block ... don't assign directly to @fiber
                resolver =
                    Resolution.new(plan, event_logger, requirement_tasks) do |_time_slice|
                        Thread.current.name = "syskit-async-resolution"
                        log_timepoint_group "syskit-async-resolution" do
                            resolver.engine.resolve_system_network(
                                requirement_tasks, **resolver_options
                            )
                        end
                    end
                @fiber = resolver
                @fiber.resume # will quickly go to the first yield
                @fiber
            end

            def resolution_requirement_tasks
                @fiber&.requirement_tasks
            end

            def default_requirement_tasks
                Engine.discover_requirement_tasks_from_plan(plan)
            end

            def start(
                requirement_tasks = default_requirement_tasks,
                time_slice:, **resolver_options
            )
                resolver = prepare(requirement_tasks, **resolver_options)
                resolver.resume(time_slice)
                resolver
            end

            def valid?(current = default_requirement_tasks)
                current.to_set == future.requirement_tasks
            end

            def cancel
                @cancelled = true
                @fiber.kill
            end

            def finished?
                @fiber.alive?
            end

            def complete?
                @fiber.complete?
            end

            def join
                @fiber.resume(nil) unless finished?

                raise @fiber.reason if @fiber.rejected?

                @fiber.value
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
                unless complete?
                    raise InvalidState,
                          "attempting to call Async#apply while processing " \
                          "is in progress"
                end

                engine = @fiber.engine
                if @cancelled
                    engine.discard_work_plan
                    nil
                elsif future.fulfilled?
                    required_instances, resolution_errors = future.value
                    begin
                        engine.apply_system_network_to_plan(
                            required_instances, **@apply_system_network_options
                        )
                        SystemNetworkPlanApplyResult.new(
                            instance_requirement_tasks: required_instances.keys,
                            errors: resolution_errors
                        )
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
