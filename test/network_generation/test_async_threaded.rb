# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe AsyncThreaded do
            describe "#poll" do
                it "ignores instance requirement tasks added to the plan after the " \
                   "resolution was started and would have succeded without errors" do
                    cmp_m = Composition.new_submodel
                    cmp = plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                    requirement_task = cmp.planning_task

                    execute { requirement_task.start! }
                    execute { Runtime.apply_requirement_modifications(plan) }
                    plan.syskit_current_resolution.network_generation_join

                    # This task should fail if listed for deployment as it has no defined
                    # deployment
                    other_m = TaskContext.new_submodel
                    other_t =
                        plan.add_permanent_task(other_m.to_instance_requirements.as_plan)
                    other_t_requirement = other_t.planning_task
                    execute { other_t_requirement.start! }

                    execute do
                        plan.syskit_current_resolution.apply_complete_network_generation
                    end
                    assert requirement_task.resolution_success_event.emitted?
                    # Ensures that other_t was never considered during the resolution as
                    # it was added after the resolution started
                    refute other_t_requirement.failed_event.emitted?
                end

                it "ignores instance requirement tasks added to the plan after the " \
                   "resolution was started and would raise an exception" do
                    skip if Syskit.conf.capture_errors_during_network_resolution?

                    task_m = TaskContext.new_submodel
                    task_t = plan.add_permanent_task(task_m.to_instance_requirements)
                    requirement_task = task_t.planning_task
                    execute { requirement_task.start! }
                    execute { Runtime.apply_requirement_modifications(plan) }
                    plan.syskit_current_resolution.network_generation_join

                    other_m = TaskContext.new_submodel
                    other_t =
                        plan.add_permanent_task(other_m.to_instance_requirements.as_plan)
                    other_t_requirement = other_t.planning_task
                    execute { other_t_requirement.start! }

                    expect_execution do
                        yield if block_given?
                        plan.syskit_join_current_resolution(raise_on_error: false)
                    end.to_have_error_matching(Roby::PlanningFailedError)

                    assert requirement_task.failed_event.emitted?
                    # Ensures that other_t was never considered during the resolution as
                    # it was added after the resolution started
                    refute other_t_requirement.failed_event.emitted?
                end
            end
        end
    end
end
