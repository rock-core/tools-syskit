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

            def initialize(plan, event_logger: plan.event_logger, thread_pool: Concurrent::CachedThreadPool.new)
                @plan = plan
                @event_logger = event_logger
                @thread_pool = thread_pool
            end

            def transaction_finalized?
                future.engine.work_plan.finalized?
            end

            def transaction_committed?
                future.engine.work_plan.committed?
            end

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

                def cancel
                    add_observer do
                        self.plan.execution_engine.queue_worker_completion_block do
                            if !engine.work_plan.finalized?
                                engine.work_plan.discard_transaction
                            end
                        end
                    end
                    super
                end
            end

            def prepare(requirement_tasks = Engine.discover_requirement_tasks_from_plan(plan))
                future.cancel if future
                resolver = Resolution.new(plan, event_logger, requirement_tasks, executor: thread_pool) do
                    log_timepoint_group 'syskit-async-resolution' do
                        resolver.engine.resolve_system_network(requirement_tasks)
                    end
                end
                @future = resolver
            end

            def start(requirement_tasks = Engine.discover_requirement_tasks_from_plan(plan))
                resolver = prepare(requirement_tasks)
                resolver.execute
                resolver
            end

            def valid?(current = Engine.discover_requirement_tasks_from_plan(plan))
                current.to_set == future.requirement_tasks
            end

            def cancel
                future.cancel
            end

            def finished?
                !future.pending?
            end

            def join
                result = future.value
                if !future.fulfilled?
                    raise future.reason
                end
                result
            end

            def apply
                engine = future.engine
                if future.fulfilled?
                    required_instances = future.value
                    begin
                        engine.apply_system_network_to_plan(required_instances)
                    rescue ::Exception => e
                        engine.work_plan.discard_transaction
                        raise e
                    end
                else
                    engine.work_plan.discard_transaction
                    raise future.reason
                end
            end
        end
    end
end

