require 'syskit/test/self'

module Syskit
    module Runtime
        describe ".update_task_states" do
            it "marks a task as failed-to-start if #may_configure? returns false" do
                component_m = Syskit::TaskContext.new_submodel
                task = syskit_stub_and_deploy(component_m)
                syskit_start_execution_agents(task)

                plan.unmark_mission_task(task)
                flexmock(task).should_receive(:may_setup?).and_return(false)
                Runtime.update_task_states(task.plan)
                assert task.failed_to_start?
                assert_equal "#{task} reports that it cannot be configured (FATAL_ERROR ?)", task.failure_reason.original_exception.message
            end
        end
    end
end
