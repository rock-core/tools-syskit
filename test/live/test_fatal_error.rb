# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class SyskitFatalErrorTests < Syskit::Test::ComponentTest
        run_live

        attr_reader :task, :task2, :deployment

        before do
            @auto_restart_flag =
                Syskit.conf.auto_restart_deployments_with_quarantined_task_contexts?


            deployment_m = OroGen::Deployments.syskit_fatal_error_recovery_test
            @task_m = OroGen.orogen_syskit_tests.FatalError
                            .deploy_with(deployment_m => Process.pid.to_s)
            @task = syskit_deploy_configure_and_start(@task_m)

            @task2_m = OroGen.orogen_syskit_tests.Empty
                             .deploy_with(deployment_m => Process.pid.to_s)
            @task2 = syskit_deploy_configure_and_start(@task2_m)
            @deployment = @task.execution_agent
        end

        after do
            Syskit.conf.auto_restart_deployments_with_quarantined_task_contexts =
                @auto_restart_flag
        end

        it "emits fatal_error" do
            trigger_fatal_error
        end

        it "marks itself as being in FATAL on its deployment" do
            # Avoid killing the deployment altogether
            trigger_fatal_error

            assert @deployment.has_fatal_errors?
            assert @deployment.task_context_in_fatal?("#{Process.pid}a")
        end

        it "does not allow respawning a task that has gone into FATAL_ERROR" do
            trigger_fatal_error

            assert_raises(TaskContextInFatal) do
                @deployment.task("#{Process.pid}a")
            end
        end

        it "fails during network generation when attempting "\
           "to deploy a component that is in FATAL_ERROR" do
            # Avoid killing the deployment altogether
            Syskit.conf.auto_restart_deployments_with_quarantined_task_contexts = false
            trigger_fatal_error

            e = assert_raises(Roby::Test::ExecutionExpectations::UnexpectedErrors) do
                syskit_deploy(@task_m)
            end
            assert_kind_of Roby::PlanningFailedError,
                           e.each_execution_exception.first.exception
        end

        it "auto-restarts deployments with fatal/quarantined tasks "\
           "if configured to do so" do
            # Make sure we let the deployer restart the deployment. Can't mock
            # opportunistic_recovery_from_quarantine as it is needed for the
            # method to work.
            Syskit.conf.auto_restart_deployments_with_quarantined_task_contexts = true

            trigger_fatal_error

            # DO NOT use syskit_configure_and_start, it forcefully starts the execution
            # agent, which does not work here.
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

        it "kills the deployment if the only non-utility tasks are in quarantine" do
            expect_execution do
                task.quarantined!
                task2.quarantined!
            end.to do # rubocop:disable Style/MultilineBlockChain
                emit task.aborted_event
                emit task2.aborted_event
                emit deployment.kill_event
                emit deployment.signaled_event
            end
        end

        it "kills the deployment if the task was the only one running on it apart "\
           "from loggers" do
            expect_execution { task2.stop! }.to { emit task2.stop_event }
            trigger_fatal_error do
                emit deployment.kill_event
                emit deployment.signaled_event
            end
        end

        it "does kill a deployment with a fatal-errored task "\
           "once all non-utility tasks have stopped" do
            trigger_fatal_error

            expect_execution { task2.stop! }
                .to do
                    emit task2.stop_event
                    emit deployment.kill_event
                    emit deployment.signaled_event
                end
        end

        def trigger_fatal_error(&block)
            expect_execution { task.stop! }.to do
                emit task.fatal_error_event
                emit task.exception_event
                instance_eval(&block) if block
            end
        end
    end
end
