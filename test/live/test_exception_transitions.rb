# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class ExceptionTransitionTest < Syskit::Test::ComponentTest
        run_live

        it "handles a task that transitions to exception in stopHook" do
            task_m = OroGen.orogen_syskit_tests.ExceptionFromStopHook
                           .deployed_as("blocking_hooks")
            task = syskit_deploy_configure_and_start(task_m)

            expect_execution { task.stop! }
                .to_emit task.custom_exception_event
        end
    end
end
