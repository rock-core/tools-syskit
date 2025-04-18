# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class SyskitFatalErrorTests < Syskit::Test::ComponentTest
        run_live

        before do
            @orig_auto_restart_flag =
                Syskit.conf.auto_restart_deployments_with_quarantines?
            @orig_opportunistic_recovery =
                Syskit.conf.opportunistic_recovery_from_quarantine?

            Syskit.conf.auto_restart_deployments_with_quarantines = false
            Syskit.conf.opportunistic_recovery_from_quarantine = false
        end

        after do
            Syskit.conf.auto_restart_deployments_with_quarantines =
                @orig_auto_restart_flag
            Syskit.conf.opportunistic_recovery_from_quarantine =
                @orig_opportunistic_recovery
        end

        describe "system handling of fatal error and quarantined tasks" do
            attr_reader :task, :task2, :deployment

            before do
                deployment_m = OroGen::Deployments.syskit_fatal_error_recovery_test
                @task_m = OroGen.orogen_syskit_tests.FatalError
                                .deploy_with(deployment_m => Process.pid.to_s)
                @task = syskit_deploy_configure_and_start(@task_m)

                @task2_m = OroGen.orogen_syskit_tests.Empty
                                 .deploy_with(deployment_m => Process.pid.to_s)
                @task2 = syskit_deploy_configure_and_start(@task2_m)
                @deployment = @task.execution_agent
            end

            it "does not allow respawning a task that has gone into FATAL_ERROR" do
                trigger_fatal_error(task)

                assert_raises(TaskContextInFatal) do
                    @deployment.task("#{Process.pid}a")
                end
            end

            it "fails during network generation when attempting " \
               "to deploy a component that is in FATAL_ERROR" do
                trigger_fatal_error(@task)

                assert_raises(TaskContextInFatal) do
                    syskit_deploy(@task_m)
                end
            end

            describe "the auto-restart behaviour" do
                before do
                    Syskit.conf.auto_restart_deployments_with_quarantines = true
                end

                it "auto-restarts deployments with a task in FATAL_ERROR " \
                   "if configured to do so" do
                    trigger_fatal_error(@task)

                    # DO NOT use syskit_configure_and_start, it forcefully starts
                    # the execution agent, which does not work here.
                    new_task = syskit_deploy(@task_m)

                    refute_equal @deployment, new_task.execution_agent
                    assert_equal "#{Process.pid}a", new_task.orocos_name
                    expect_execution.scheduler(true).garbage_collect(true)
                                    .to { emit new_task.start_event }

                    # Make sure task2 got restarted too
                    assert @task2.finished?
                    assert plan.find_tasks.with_arguments(orocos_name: "#{Process.pid}b")
                               .running.first
                end

                it "does not auto-restart the deployment if the tasks " \
                   "in FATAL_ERROR are not involved in the new network" do
                    trigger_fatal_error(@task)

                    new_task = syskit_deploy(@task2_m)
                    assert_same @task2, new_task
                end

                it "auto-restarts deployments with a quarantined task " \
                   "if configured to do so" do
                    @task.quarantined!
                    plan.unmark_mission_task(@task) # avoids QuarantinedTaskError

                    # DO NOT use syskit_configure_and_start, it forcefully starts
                    # the execution agent, which does not work here.
                    new_task = FlexMock.use(@deployment) do |deployment_mock|
                        deployment_mock.should_receive(scheduled_for_kill?: false)
                        syskit_deploy(@task_m)
                    end

                    refute_equal @deployment, new_task.execution_agent
                    assert_equal "#{Process.pid}a", new_task.orocos_name
                    expect_execution
                        .scheduler(true).garbage_collect(true)
                        .to do
                            emit task.aborted_event
                            emit new_task.start_event
                        end

                    # Make sure task2 got restarted too
                    assert @task2.finished?
                    assert plan.find_tasks.with_arguments(orocos_name: "#{Process.pid}b")
                               .running.first
                end

                it "does not auto-restart the deployment if quarantined " \
                   "tasks are not involved in the new network" do
                    @task.quarantined!
                    plan.unmark_mission_task(@task) # avoid QuarantinedTaskError

                    new_task = syskit_deploy(@task2_m)
                    assert_same @task2, new_task
                    # Kill the deployment ourselves to avoid warnings on teardown
                    expect_execution { task.execution_agent.stop! }
                        .to do
                            emit task.execution_agent.stop_event
                            emit task.aborted_event
                            emit task2.aborted_event
                        end
                end
            end

            describe "opportunistic recovery" do
                before do
                    Syskit.conf.opportunistic_recovery_from_quarantine = true
                end

                it "kills the deployment if the task was the only one running on it " \
                   "apart from loggers" do
                    expect_execution { task2.stop! }.to { emit task2.stop_event }
                    trigger_fatal_error(@task) do
                        emit deployment.kill_event
                        emit deployment.signaled_event
                    end
                end

                it "does kill a deployment with a fatal-errored task " \
                   "once all non-utility tasks have stopped" do
                    trigger_fatal_error(@task)

                    expect_execution { task2.stop! }
                        .to do
                            emit task2.stop_event
                            emit deployment.kill_event
                            emit deployment.signaled_event
                        end
                end

                it "kills the deployment if the only non-utility tasks " \
                   "are in quarantine" do
                    plan.unmark_mission_task(task)
                    plan.unmark_mission_task(task2)
                    expect_execution do
                        task.quarantined!
                        task2.quarantined!
                    end.to do
                        quarantine task
                        quarantine task2
                        emit task.aborted_event
                        emit task2.aborted_event
                        emit deployment.kill_event
                        emit deployment.signaled_event
                    end
                end
            end
        end

        describe "the fatal error event" do
            it "emits fatal_error" do
                task_m = OroGen.orogen_syskit_tests.FatalError
                               .deployed_as(default_deployment_name)
                task = syskit_deploy_configure_and_start(task_m)
                trigger_fatal_error(task)
            end

            it "handles a delay between the fatal error and the component " \
               "returning from stop" do
                task_m = OroGen.orogen_syskit_tests.FatalError
                               .deployed_as(default_deployment_name)
                task = syskit_deploy(task_m)
                task.properties.stop_return_delay_after_fatal_ms = 5_000
                syskit_configure_and_start(task)
                plan.unmark_permanent_task(task.execution_agent)
                flexmock(task).should_receive(:quarantined!).never
                expect_execution { task.stop! }
                    .garbage_collect(true).join_all_waiting_work(false)
                    .to do
                        emit task.fatal_error_event
                        emit task.execution_agent.stop_event
                    end
            end

            it "marks itself as being in FATAL on its deployment" do
                task_m = OroGen.orogen_syskit_tests.FatalError
                               .deployed_as(default_deployment_name)
                task = syskit_deploy_configure_and_start(task_m)
                deployment = task.execution_agent
                trigger_fatal_error(task)

                assert deployment.has_fatal_errors?
                assert deployment.task_context_in_fatal?(default_deployment_name)
            end

            it "handles the asynchronicity between a possible exception event and a " \
               "fatal error" do
                task_m = OroGen.orogen_syskit_tests.FatalErrorAfterExceptionAndDelay
                               .deployed_as(default_deployment_name)
                task = syskit_deploy_and_configure(task_m)
                expect_execution { task.start! }
                    .to do
                        emit task.exception_event
                        emit task.fatal_error_event
                    end
            end

            it "waits for the final transition to be present on the state connection " \
               "to stop the task" do
                task_m = OroGen.orogen_syskit_tests.FatalErrorAfterExceptionAndDelay
                               .deployed_as(default_deployment_name)
                task = syskit_deploy(task_m)
                task.properties.update_delay_ms = 0
                task.properties.stop_delay_ms = 0
                syskit_configure(task)

                FlexMock.use(task) do |task_mock|
                    task_mock
                        .should_receive(:update_orogen_state_in_exception)
                        .with(nil).pass_thru

                    task_mock
                        .should_receive(:update_orogen_state_in_exception)
                        .with(:FATAL_ERROR)

                    expect_execution { task.start! }
                        .to do
                            not_emit task.exception_event, within: 1
                            not_emit task.fatal_error_event, within: 1
                        end
                end

                # :FATAL_ERROR won't come by itself. Cheat
                task.push_pending_exception_state(:FATAL_ERROR)
                expect_execution
                    .to do
                        emit task.exception_event
                        emit task.fatal_error_event
                    end
            end
        end

        def trigger_fatal_error(task, &block)
            expect_execution { task.stop! }.to do
                emit task.fatal_error_event
                emit task.exception_event
                instance_eval(&block) if block
            end
        end

        def default_deployment_name
            "#{name}-#{Process.pid}"
        end
    end
end
