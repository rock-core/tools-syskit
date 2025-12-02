# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe AsyncThreaded do
            before do
                plan.syskit_async_method = AsyncThreaded
            end

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
                        plan.syskit_current_resolution.finalize
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
                        plan.syskit_join_current_resolution(raise_on_error: false)
                    end.to_have_error_matching(Roby::PlanningFailedError)

                    assert requirement_task.failed_event.emitted?
                    # Ensures that other_t was never considered during the resolution as
                    # it was added after the resolution started
                    refute other_t_requirement.failed_event.emitted?
                end
            end

            describe "#cancel" do
                it "discards the transaction once the future finishes" do
                    latch = Concurrent::IVar.new
                    flexmock(Engine)
                        .new_instances.should_receive(:resolve_system_network)
                        .and_return { latch.value }

                    async = AsyncThreaded.start(plan, Set[requirement_task_mock])
                    work_plan = async.engine.work_plan
                    flexmock(async.engine)
                        .should_receive(:discard_work_plan).once
                        .pass_thru
                    async.cancel
                    latch.set true
                    async.poll(nil) until async.finished?

                    assert work_plan.finalized?
                end
            end

            describe "#poll" do
                it "applies the computed network on the plan" do
                    requirements = Set[requirement_task_mock]
                    async = AsyncThreaded.start(plan, requirements)
                    engine = flexmock(async.engine, :strict)
                    engine.should_receive(:resolve_system_network)
                          .with(requirements, any).once
                          .and_return(ret = { requirements => [] })

                    engine.should_receive(:apply_system_network_to_plan)
                          .with(ret).once

                    async.network_generation_result # waits for the thread
                    execute { async.poll(nil) }
                    assert async.finished?
                end

                it "carries forward options relevant to applying " \
                   "the network to the existing plan" do
                    requirements = Set[requirement_task_mock]
                    async = AsyncThreaded.start(
                        plan, requirements,
                        resolver_options: { compute_deployments: false }
                    )
                    engine = flexmock(async.engine, :strict)
                    engine.should_receive(:resolve_system_network)
                          .with(requirements, any).once
                          .and_return(ret = { requirements => [] })
                    engine.should_receive(:apply_system_network_to_plan)
                          .with(ret, compute_deployments: false).once
                    async.network_generation_result # waits for the future to finish
                    execute { async.poll(nil) }
                    assert async.finished?
                end

                it "discards the transcation if applying the plan fails" do
                    error_t = Class.new(RuntimeError)
                    requirements = Set[requirement_task_mock]
                    async = AsyncThreaded.start(plan, requirements)
                    engine = flexmock(async.engine, :strict)
                    engine.should_receive(:resolve_system_network)
                          .and_return(flexmock)
                    engine.should_receive(:apply_system_network_to_plan)
                          .and_raise(error_t)
                    flexmock(engine).should_receive(:discard_work_plan).once.pass_thru
                    async.network_generation_result
                    execute { async.poll(nil) }
                end

                it "passes any exception raised inside the future and discards the " \
                   "transaction" do
                    error_t = Class.new(RuntimeError)
                    requirements = Set[requirement_task_mock]
                    async = AsyncThreaded.start(plan, requirements)
                    engine = flexmock(async.engine, :strict)
                    engine.should_receive(:resolve_system_network).and_raise(error_t)
                    engine.should_receive(:apply_system_network_to_plan).never
                    flexmock(async.engine)
                        .should_receive(:discard_work_plan)
                        .once.pass_thru
                    async.network_generation_result
                    execute { async.poll(nil) }
                    assert async.finished?
                end
            end

            def requirement_task_m
                @requirement_task_m ||= Roby::Task.new_submodel do
                    terminates

                    event :resolution_success
                end
            end

            def requirement_task_mock
                plan.add(task = requirement_task_m.new)
                execute { task.start_event.emit }
                task
            end
        end
    end
end
