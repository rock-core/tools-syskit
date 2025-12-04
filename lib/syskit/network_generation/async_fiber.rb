# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # A partially asynchronous requirement resolver built on top of {Engine}
        class AsyncFiber < Async
            # Object that is passed to the network generation process to handle
            # cancellations and yield
            class Control < Async::Control
                # @param [Float] slice the allowed computation slice in seconds.
                #   The network generation process will yield back after this long,
                #   ensuring that the main thread can do some processing
                def initialize(slice)
                    super()

                    @slice = slice
                    @slice_deadline = Time.now + slice
                end

                # (see Async::Control#interruption_point)
                def interruption_point(
                    event_logger, name, log_on_interruption_only: false
                )
                    return super if Time.now < @slice_deadline

                    event_logger.log_timepoint "#{name}:interrupt"
                    cancelled = Fiber.yield
                    event_logger.log_timepoint "#{name}:resume"
                    @slice_deadline = Time.now + @slice
                    !cancelled
                end
            end

            def initialize(
                plan, requirement_tasks,
                slice: Syskit.conf.resolution_time_slice,
                event_logger: plan.event_logger, resolver_options: {}
            )
                super(plan, requirement_tasks,
                      resolution_control: Control.new(slice),
                      event_logger: event_logger, resolver_options: resolver_options)

                # Protect all Component instances against garbage collection
                # by adding them in a transaction. This is to make sure we don't
                # tear down, during network generation, subparts of the old network
                # that are actually needed by the new network.
                @keepalive = Roby::Transaction.new(plan)
                plan.find_local_tasks(Component).each do |component_task|
                    @keepalive.wrap(component_task) unless component_task.finished?
                end

                log_timepoint("syskit-netgen:async-fiber-start")

                @fiber = Fiber.new do
                    catch(:syskit_netgen_cancelled) do
                        async_phase
                    end
                end
            end

            def async_phase
                begin
                    network_generation_result =
                        log_timepoint_group "syskit-netgen:gen" do
                            @engine.resolve_system_network(
                                @requirement_tasks, **@resolver_options
                            )
                        end
                rescue Exception => e # rubocop:disable Lint/RescueException
                    network_generation_error = e
                end

                @async_phase_running_requirements =
                    @requirement_tasks.find_all(&:running?)

                @async_phase_result =
                    log_timepoint_group "syskit-netgen:apply" do
                        apply_network_generation(
                            result: network_generation_result,
                            error: network_generation_error
                        )
                    end
            rescue Exception => e # rubocop:disable Lint/RescueException
                @async_phase_error = e
            end

            def self.start(
                plan, requirement_tasks = default_requirement_tasks, resolver_options: {}
            )
                new(plan, requirement_tasks, resolver_options: resolver_options)
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

                return @fiber.resume(cancelled?) unless async_phase_finished?

                finalize
            end

            def async_phase_finished?
                !@fiber.alive?
            end

            def finalize
                if cancelled?
                    @engine.discard_work_plan
                    return
                elsif @async_phase_error
                    @async_phase_result = update_instance_requirement_tasks_on_exception(
                        @async_phase_running_requirements, @async_phase_error
                    )
                    return
                end

                return unless @async_phase_result

                update_instance_requirement_tasks_on_result(@async_phase_result)
            ensure
                finished!
            end

            def result
                @async_phase_result
            end

            def finished!
                @finished = true
                @keepalive.discard_transaction unless @keepalive.finalized?
                log_timepoint("syskit-netgen:async-fiber-finished")
            end

            # Wait for the resolution to finish and either apply the result or raise if
            # there is an error
            def join(raise_on_error: true)
                @fiber.resume(cancelled?) until async_phase_finished?

                if raise_on_error
                    _, _, exception = @async_phase_result
                    raise exception if exception
                end

                poll(nil)
            end
        end
    end
end
