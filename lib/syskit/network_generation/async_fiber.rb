# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class AsyncFiber < Async
            def initialize(
                plan, requirement_tasks,
                event_logger: plan.event_logger, **resolver_options
            )
                super

                @keepalive = Roby::Transaction.new(plan)
                plan.find_local_tasks(Component).each do |component_task|
                    @keepalive.wrap(component_task) unless component_task.finished?
                end

                # Resolver is used within the block ... don't assign directly to @future
                @fiber = Fiber.new do
                    begin
                        network_generation_result =
                            log_timepoint_group "syskit-network-generation" do
                                @engine.resolve_system_network(
                                    requirement_tasks, **resolver_options
                                )
                            end
                    rescue Exception => e
                        network_generation_error = e
                    end

                    @async_phase_running_requirements =
                        @requirement_tasks.find_all(&:running?)

                    @async_phase_result =
                        log_timepoint_group "syskit-apply-network-generation" do
                            apply_network_generation(
                                result: network_generation_result,
                                error: network_generation_error
                            )
                        end
                rescue Exception => e # rubocop:disable Lint/RescueException
                    @async_phase_error = e
                end
            end

            def self.start(
                plan, requirement_tasks = default_requirement_tasks, **resolver_options
            )
                new(plan, requirement_tasks, **resolver_options)
            end

            def finished?
                @finished
            end

            # Periodic polling of the resolution process
            #
            # @param [nil,Set<InstanceRequirementTask>] requirement_tasks the requirements
            #   that currently need to be resolved. The class will cancel the current
            #   resolution if it does not match the set it is actually resolving. Pass
            #   nil to ignore the test altogether
            def poll(requirement_tasks)
                return if finished?
                cancel if !cancelled? && requirement_tasks && !valid?(requirement_tasks)

                return @fiber.resume unless async_phase_finished?

                finalize
            end

            def async_phase_finished?
                !@fiber.alive?
            end

            def finalize
                if @async_phase_error
                    update_instance_requirement_tasks_on_exception(
                        @async_phase_running_requirements, @async_phase_error
                    )
                elsif !@async_phase_result
                    return
                else
                    update_instance_requirement_tasks_on_result(@async_phase_result)
                end
            ensure
                finished!
            end

            def finished!
                @finished = true
                @keepalive.discard_transaction
            end

            # Wait for the resolution to finish and either apply the result or raise if
            # there is an error
            def join(raise_on_error: true)
                @fiber.resume until async_phase_finished?

                if raise_on_error
                    _, _, exception = @async_phase_result
                    raise exception if exception
                end

                poll(nil)
            end
        end
    end
end
