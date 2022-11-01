# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class CustomStatesTest < Syskit::Test::ComponentTest
        run_live

        attr_reader :task

        before do
            @task = syskit_deploy(
                OroGen.orogen_syskit_tests.CustomStates.deployed_as("test")
            )
        end

        it "emits events for custom runtime states" do
            task.properties.level = 0
            syskit_configure(task)
            expect_execution { task.start! }
                .to { emit task.custom_runtime_event }
        end

        it "emits events for custom error states" do
            task.properties.level = 1
            syskit_configure(task)
            expect_execution { task.start! }
                .to { emit task.custom_error_event }
        end

        it "emits events for custom exception states" do
            task.properties.level = 2
            syskit_configure(task)
            expect_execution { task.start! }
                .to { emit task.custom_exception_event }
        end
    end
end
