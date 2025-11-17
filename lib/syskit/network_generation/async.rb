# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # Base class and interface definition for the async resolver used
        # by {Runtime.apply_requirements_modification}
        class Async
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            attr_reader :event_logger, :requirement_tasks

            ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK = %I[
                compute_deployments garbage_collect validate_final_network
            ].freeze

            # Whether the network generation step is finished
            def network_generation_complete?
                raise NotImplementedError, __method__
            end

            # Whether the network generation step is finished and successful
            def network_generation_successful?
                raise NotImplementedError, __method__
            end

            # In case the network generation step is successful, return its result
            #
            # @return a pair, (required_instances, resolution_errors)
            def network_generation_result
                raise NotImplementedError, __method__
            end

            # In case the network generation step raised an exception, return it
            def network_generation_error
                raise NotImplementedError, __method__
            end

            def initialize(
                plan, requirement_tasks,
                resolver_options: {}, event_logger: plan.event_logger
            )
                @plan = plan
                @event_logger = event_logger
                @requirement_tasks = requirement_tasks

                @engine = Engine.new(plan, event_logger: @event_logger)
                @resolver_options = resolver_options
                @apply_system_network_options = resolver_options.slice(
                    *ENGINE_OPTIONS_CARRIED_TO_APPLY_SYSTEM_NETWORK
                )
            end

            def transaction_finalized?
                engine.work_plan.finalized?
            end

            def transaction_committed?
                engine.work_plan.committed?
            end

            # Check if this resolution is still up-to-date
            #
            # The method checks whether the list of requirements processed by this
            # resolution is the same than the current list. If not, the system will
            # (probably) cancel the resolution to start a new one
            def valid?(current = default_requirement_tasks)
                current.to_set == @requirement_tasks
            end

            # Cancel this resolution
            #
            # This is only signalling that the resolution should be cancelled. The
            # cancellation itself might take some time
            def cancel
                @cancelled = true
            end

            # Whether this resolution has been cancelled
            def cancelled?
                @cancelled
            end

            class InvalidState < RuntimeError; end

            # Common implementation of the logic that applies the result of the network
            # generation step
            #
            # It relies on methods implemented in the base class
            #
            # @return [nil,SystemNetworkPlanApplyResult] the application result, which is
            #   nil in case of failure or cancellation and a result object otherwise
            def apply_network_generation
                unless network_generation_complete?
                    raise InvalidState,
                          "attempting to call Async#apply_network_generation while " \
                          "processing is in progress"
                end

                if cancelled?
                    @engine.discard_work_plan
                    nil
                elsif network_generation_successful?
                    required_instances, resolution_errors = network_generation_result
                    begin
                        @engine.apply_system_network_to_plan(
                            required_instances, **@apply_system_network_options
                        )
                        SystemNetworkPlanApplyResult.new(
                            instance_requirement_tasks: required_instances.keys,
                            errors: resolution_errors
                        )
                    rescue ::Exception => e
                        @engine.handle_resolution_exception(e, on_error: Engine.on_error)
                        raise e
                    end
                else
                    error = network_generation_error
                    @engine.handle_resolution_exception(error, on_error: Engine.on_error)
                    raise error
                end
            end

            def default_requirement_tasks
                Engine.discover_requirement_tasks_from_plan(@plan)
            end

            def update_instance_requirement_tasks_on_result(result)
                result.instance_requirement_tasks.each do |t|
                    t.resolution_success_event.emit
                end
                result.errors.group_by(&:planning_task).each do |t, e|
                    t.failed_event.emit(*e.flat_map(&:original_exception)) if t.running?
                end
            end

            def update_instance_requirement_tasks_on_exception(
                requirement_tasks, exception
            )
                old, new = requirement_tasks.partition(&:resolution_success?)
                new.each { |t| t.failed_event.emit(exception) }
                NetworkGeneration::SystemNetworkPlanApplyResult.new(
                    errors: [exception], instance_requirement_tasks: old
                )
            end
        end
    end
end
