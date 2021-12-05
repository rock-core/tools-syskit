# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class KillWhileStopping < Syskit::Test::ComponentTest
        run_live

        it "can concurrently kill the deployment while the task is being stopped" do
            fatal_error_m = OroGen.orogen_syskit_tests.FatalErrorAfterExceptionAndDelay
                                  .deployed_as("fatal_error_testcase")
            fatal_error = syskit_deploy(fatal_error_m)
            fatal_error.properties.update_delay_ms = 2000
            fatal_error.properties.stop_delay_ms = 0
            fatal_error.exception_event.on do |event|
                event.task.execution_agent&.stop!
            end

            syskit_configure_and_start(fatal_error)

            deployment = fatal_error.execution_agent
            expect_execution.join_all_waiting_work(false).timeout(600).to do
                emit fatal_error.exception_event
                emit deployment.stop_event
            end
        end
    end
end
