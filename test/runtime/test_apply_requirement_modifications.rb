# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Runtime
        describe ".apply_requirement_modifications" do
            it "does nothing by default" do
                Runtime.apply_requirement_modifications(plan)
                refute plan.syskit_current_resolution
            end

            it "starts an async resolution when new IR tasks are started" do
                cmp_m = Composition.new_submodel
                requirement_task = plan.add_permanent_task(cmp_m)
                execute { requirement_task.planning_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }
                assert plan.syskit_current_resolution
                assert_equal Set[requirement_task.planning_task],
                             plan.syskit_current_resolution.future.requirement_tasks
            end

            it "restarts the current async resolution if a new IR task appears" do
                cmp_m = Composition.new_submodel
                requirement_tasks = []
                requirement_tasks << plan.add_permanent_task(cmp_m)
                execute { requirement_tasks[0].planning_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }

                requirement_tasks << plan.add_permanent_task(cmp_m)
                assert_resolution_cancelled do
                    execute { requirement_tasks[1].planning_task.start! }
                end

                assert plan.syskit_current_resolution
                assert_equal Set[*requirement_tasks.map(&:planning_task)],
                             plan.syskit_current_resolution.future.requirement_tasks
            end

            it "stops the current async resolution all running IR tasks became useless" do
                cmp_m = Composition.new_submodel
                requirement_task = plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                execute { requirement_task.planning_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }

                assert_resolution_cancelled do
                    execute { plan.unmark_permanent_task(requirement_task) }
                end

                refute plan.syskit_current_resolution
            end

            it "restarts an async resolution if one of the IR tasks became useless" do
                cmp_m = Composition.new_submodel
                requirement_tasks = []
                requirement_tasks << plan.add_permanent_task(cmp_m)
                requirement_tasks << plan.add_permanent_task(cmp_m)
                execute do
                    requirement_tasks.each { |t| t.planning_task.start! }
                end
                Runtime.apply_requirement_modifications(plan)

                assert_resolution_cancelled do
                    execute { plan.unmark_permanent_task(requirement_tasks[1]) }
                end

                assert plan.syskit_current_resolution
                assert_equal Set[requirement_tasks[0].planning_task],
                             plan.syskit_current_resolution.future.requirement_tasks
            end

            it "cancels an async resolution if one of the IR tasks "\
               "has been interrupted" do
                cmp_m = Composition.new_submodel
                requirement_task = plan.add_permanent_task(cmp_m)
                execute { requirement_task.planning_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }

                assert_resolution_cancelled do
                    expect_execution { requirement_task.planning_task.stop! }
                        .to { have_error_matching Roby::PlanningFailedError }
                end

                refute plan.syskit_current_resolution
            end

            it "applies the computed network and emits the planning task's success event" do
                cmp_m = Composition.new_submodel
                plan.add_permanent_task(requirement_task = cmp_m.to_instance_requirements.as_plan)
                requirement_task = requirement_task.planning_task
                execute { requirement_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }
                plan.syskit_current_resolution.future.value
                execute { Runtime.apply_requirement_modifications(plan) }
                assert requirement_task.success?
            end

            it "applies the computed network and emits the planning task's failed event if it raises" do
                task_m = TaskContext.new_submodel
                requirement_task = plan.add_permanent_task(task_m.to_instance_requirements.as_plan)
                requirement_task = requirement_task.planning_task
                execute { requirement_task.start! }
                execute { Runtime.apply_requirement_modifications(plan) }
                plan.syskit_current_resolution.future.value
                expect_execution { Runtime.apply_requirement_modifications(plan) }
                    .to { have_error_matching Roby::PlanningFailedError }
                assert requirement_task.failed?
                assert_kind_of Syskit::MissingDeployments, requirement_task.failed_event.last.context.first
                assert_exception_can_be_pretty_printed(requirement_task.failed_event.last.context.first)
            end

            def assert_resolution_cancelled # rubocop:disable Metrics/AbcSize
                flexmock(plan.syskit_current_resolution)
                    .should_receive(:cancel).at_least.once
                    .pass_thru

                yield

                execute do
                    # This one triggers the cancellation
                    Runtime.apply_requirement_modifications(plan)

                    # This one is necessary if the future has started to be processed
                    if plan.syskit_has_async_resolution?
                        assert plan.syskit_current_resolution&.cancelled?
                        plan.syskit_join_current_resolution
                    end

                    refute plan.syskit_current_resolution
                    Runtime.apply_requirement_modifications(plan)
                end
            end
        end
    end
end
