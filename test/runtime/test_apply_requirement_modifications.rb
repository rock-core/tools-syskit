require 'syskit/test/self'

module Syskit
    module Runtime
        describe ".apply_requirement_modifications" do
            it "does nothing by default" do
                Runtime.apply_requirement_modifications(plan)
                assert !plan.syskit_current_resolution
            end

            it "starts an async resolution when new IR tasks are started" do
                cmp_m = Composition.new_submodel
                plan.add_permanent_task(requirement_task = cmp_m.to_instance_requirements.as_plan)
                requirement_task.planning_task.start!
                Runtime.apply_requirement_modifications(plan)
                assert plan.syskit_current_resolution
                assert_equal Set[requirement_task.planning_task],
                    plan.syskit_current_resolution.future.requirement_tasks
            end

            it "restarts the current async resolution if a new IR task appeared" do
                cmp_m = Composition.new_submodel
                requirement_tasks = Array.new
                requirement_tasks << plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                requirement_tasks[0].planning_task.start!
                Runtime.apply_requirement_modifications(plan)

                requirement_tasks << plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                requirement_tasks[1].planning_task.start!
                flexmock(plan.syskit_current_resolution).should_receive(:cancel).once
                Runtime.apply_requirement_modifications(plan)

                assert plan.syskit_current_resolution
                assert_equal Set[*requirement_tasks.map(&:planning_task)],
                    plan.syskit_current_resolution.future.requirement_tasks
            end

            it "stops the current async resolution all running IR tasks became useless" do
                cmp_m = Composition.new_submodel
                requirement_task = plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                requirement_task.planning_task.start!
                Runtime.apply_requirement_modifications(plan)

                flexmock(plan.syskit_current_resolution).should_receive(:cancel).once
                plan.unmark_permanent_task(requirement_task)
                Runtime.apply_requirement_modifications(plan)

                assert !plan.syskit_current_resolution
            end

            it "restarts an async resolution if one of the IR tasks became useless" do
                cmp_m = Composition.new_submodel
                requirement_tasks = Array.new
                requirement_tasks << plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                requirement_tasks << plan.add_permanent_task(cmp_m.to_instance_requirements.as_plan)
                requirement_tasks.each { |t| t.planning_task.start! }
                Runtime.apply_requirement_modifications(plan)

                flexmock(plan.syskit_current_resolution).should_receive(:cancel).once
                plan.unmark_permanent_task(requirement_tasks[1])
                Runtime.apply_requirement_modifications(plan)

                assert plan.syskit_current_resolution
                assert_equal Set[requirement_tasks[0].planning_task],
                    plan.syskit_current_resolution.future.requirement_tasks
            end

            it "cancels an async resolution if one of the IR tasks has been interrupted" do
                cmp_m = Composition.new_submodel
                plan.add_permanent_task(requirement_task = cmp_m.to_instance_requirements.as_plan)
                requirement_task.planning_task.start!
                Runtime.apply_requirement_modifications(plan)

                flexmock(plan.syskit_current_resolution).should_receive(:cancel).once
                assert_raises(Roby::PlanningFailedError) { requirement_task.planning_task.stop! }
                Runtime.apply_requirement_modifications(plan)

                assert !plan.syskit_current_resolution
            end

            it "applies the computed network and emits the planning task's success event" do
                cmp_m = Composition.new_submodel
                plan.add_permanent_task(requirement_task = cmp_m.to_instance_requirements.as_plan)
                requirement_task = requirement_task.planning_task
                requirement_task.start!
                Runtime.apply_requirement_modifications(plan)
                plan.syskit_current_resolution.future.value
                Runtime.apply_requirement_modifications(plan)
                assert requirement_task.success?
            end

            it "applies the computed network and emits the planning task's failed event if it raises" do
                task_m = TaskContext.new_submodel
                requirement_task = plan.add_permanent_task(task_m.to_instance_requirements.as_plan)
                requirement_task = requirement_task.planning_task
                requirement_task.start!
                Runtime.apply_requirement_modifications(plan)
                plan.syskit_current_resolution.future.value
                assert_raises(Roby::PlanningFailedError) { Runtime.apply_requirement_modifications(plan) }
                assert requirement_task.failed?
                assert_kind_of Syskit::MissingDeployments, requirement_task.failed_event.last.context.first
            end
        end
    end
end

