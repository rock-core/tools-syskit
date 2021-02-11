# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test"

module Syskit
    module Test
        describe InstanceRequirementPlanningHandler do
            include InstanceRequirementPlanningHandler::Options

            before do
                @task_m = Syskit::TaskContext.new_submodel(name: "Task")
                @srv_m = Syskit::DataService.new_submodel(name: "Srv")
                @cmp_m = Syskit::Composition.new_submodel(name: "Cmp")
                @cmp_m.add @srv_m, as: "srv"
            end

            after do
                @event_loop_monitor&.dispose
            end

            it "stubs a network mingled with non-Syskit tasks" do
                plan.add(t0 = Roby::Tasks::Simple.new)
                plan.add(t1 = Roby::Tasks::Simple.new)
                task = t0.depends_on(@task_m, role: "task")
                cmp = t0.depends_on(@cmp_m, role: "cmp")
                t0.depends_on(t1, role: "plain_task")
                t1.depends_on(task, role: "task")

                t0 = run_planners(t0)
                refute_same t0.cmp_child, cmp
                assert_kind_of @cmp_m, t0.cmp_child
                assert_kind_of @srv_m, t0.cmp_child.srv_child
                assert_kind_of @task_m, t0.task_child
                assert_same t0.task_child, t0.plain_task_child.task_child

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start t0.task_child
                    start t0.cmp_child
                    start t0.cmp_child.srv_child
                    start t0.plain_task_child.task_child
                end
            end

            it "triggers resolution immediately if the planning tasks are running" do
                plan.add(cmp = @cmp_m.as_plan)
                planning_task = cmp.planning_task
                execute { planning_task.start! }

                cycles = gather_planning_state(cmp, 1)
                run_planners(cmp)

                assert_equal false, cycles[0].planning_task_starting
                assert_equal true, cycles[0].planning_task_running
                assert cycles[0].has_async_resolution
            end

            it "waits for the planning tasks to be started before it triggers the async resolution" do
                plan.add(cmp = @cmp_m.as_plan)
                cycles = gather_planning_state(cmp, 2)
                run_planners(cmp)

                assert_equal true, cycles[0].planning_task_starting
                assert_equal false, cycles[0].planning_task_running
                refute cycles[0].has_async_resolution

                assert_equal false, cycles[1].planning_task_starting
                assert_equal true, cycles[1].planning_task_running
                assert cycles[1].has_async_resolution
            end

            it "considers only the provided tasks" do
                plan.add(task = @task_m.as_plan)
                plan.add(cmp = @cmp_m.as_plan)

                cmp = run_planners(cmp)
                assert_equal [task], plan.find_tasks(@task_m).to_a

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.srv_child
                end
            end

            it "handles a planning error" do
                plan.add(cmp = @cmp_m.as_plan)

                error = syskit_run_planner_with_full_deployment do
                    expect_execution { cmp = run_planners(cmp) }
                        .to { have_error_matching Roby::PlanningFailedError.match }
                end

                assert_equal cmp.to_task, error.origin
            end

            it "optionally attempts to deploy the network" do
                plan.add(cmp = @cmp_m.as_plan)

                syskit_run_planner_with_full_deployment do
                    assert syskit_run_planner_deploy_network?
                    assert syskit_run_planner_validate_network?
                    assert syskit_run_planner_stub?

                    expect_execution { run_planners(cmp) }
                        .to { have_error_matching Roby::PlanningFailedError.match }
                end
                refute syskit_run_planner_deploy_network?
                refute syskit_run_planner_validate_network?
                assert syskit_run_planner_stub?
            end

            it "stubs the result by default" do
                plan.add(cmp = @cmp_m.as_plan)

                cmp = run_planners(cmp)
                refute cmp.srv_child.abstract?
            end

            it "optionally does not stub the result" do
                plan.add(cmp = @cmp_m.as_plan)

                self.syskit_run_planner_stub = false
                cmp = run_planners(cmp)
                assert cmp.srv_child.abstract?
            end

            PlanningState = Struct.new(
                :planning_task_starting,
                :planning_task_running,
                :has_async_resolution
            )

            def gather_planning_state(root_task, cycle_count)
                data = []
                planning_task = root_task.planning_task
                @event_loop_monitor = execution_engine.add_propagation_handler(type: :propagation) do
                    if data.size < cycle_count
                        data << PlanningState.new(
                            planning_task.starting?,
                            planning_task.running?,
                            plan.syskit_has_async_resolution?
                        )
                    end
                end
                data
            end
        end
    end
end
