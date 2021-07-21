# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class SyskitFatalErrorTests < Syskit::Test::ComponentTest
        run_live

        attr_reader :task, :deployment

        before do
            @task = syskit_deploy_configure_and_start(
                OroGen.orogen_syskit_tests.FatalError
                        .deployed_as("syskit-tests-fatal-error")
            )
            @deployment = @task.execution_agent
        end

        it "emits fatal_error" do
            trigger_fatal_error
        end

        it "marks itself as being in FATAL on its deployment" do
            # Avoid killing the deployment altogether
            flexmock(@deployment).should_receive(:opportunistic_recovery_from_quarantine)
            trigger_fatal_error

            assert @deployment.has_fatal_errors?
            assert @deployment.task_context_in_fatal?("syskit-tests-fatal-error")
        end

        it "does not allow respawning a task that has gone into FATAL_ERROR" do
            # Avoid killing the deployment altogether
            flexmock(@deployment).should_receive(:opportunistic_recovery_from_quarantine)
            trigger_fatal_error

            assert_raises(TaskContextInFatal) do
                @deployment.task("syskit-tests-fatal-error")
            end
        end

        it "fails during network generation when attempting "\
           "to deploy a component that is in FATAL_ERROR" do
            # Avoid killing the deployment altogether
            flexmock(@deployment).should_receive(:opportunistic_recovery_from_quarantine)
            trigger_fatal_error

            e = assert_raises(Roby::Test::ExecutionExpectations::UnexpectedErrors) do
                syskit_deploy(
                    OroGen.orogen_syskit_tests.FatalError
                            .deployed_as("syskit-tests-fatal-error")
                )
            end
            assert_kind_of Roby::PlanningFailedError,
                           e.each_execution_exception.first.exception
        end

        it "kills the deployment if the only non-utility tasks are in quarantine" do
            expect_execution do
                task.quarantined!
            end.to do
                emit task.stop_event
                emit deployment.kill_event
                emit deployment.signaled_event
            end
        end

        it "kills the deployment if the task was the only one running on it apart "\
           "from loggers" do
            trigger_fatal_error do
                emit deployment.kill_event
                emit deployment.signaled_event
            end
        end

        it "does kill a deployment with a fatal-errored task "\
           "once all non-utility tasks have stopped" do
            flexmock(Roby.app).should_receive(:syskit_utility_component?)
                              .and_return(false)
            trigger_fatal_error

            logger = @deployment.each_executed_task.first
            syskit_configure_and_start(logger)
            expect_execution { logger.stop! }
                .to do
                    emit deployment.kill_event
                    emit deployment.signaled_event
                end
        end

        it "does kill a deployment with a fatal-errored task "\
           "once all non-utility tasks have stopped" do
            flexmock(Roby.app).should_receive(:syskit_utility_component?)
                              .and_return(false)
            trigger_fatal_error

            logger = @deployment.each_executed_task.first
            syskit_configure_and_start(logger)
            expect_execution { logger.stop! }
                .to do
                    emit deployment.kill_event
                    emit deployment.signaled_event
                end
        end

        it "kills the deployment if the task was the only one running on it" do
            trigger_fatal_error do
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
