require 'syskit/test/self'

module Syskit
    module Runtime
        describe ".update_task_states" do
            it "does not call #will_never_setup? if the task has a configuration precedence" do
                component_m = Syskit::TaskContext.new_submodel
                task0 = syskit_stub_and_deploy(component_m)
                task1 = syskit_stub_and_deploy(component_m)
                task0.should_configure_after task1.start_event
                syskit_start_execution_agents(task0)
                syskit_start_execution_agents(task1)

                flexmock(task0).should_receive(:will_never_setup?).never
                Runtime.update_task_states(task0.plan)
            end
            it "marks a task as failed-to-start if #will_never_setup? returns false" do
                component_m = Syskit::TaskContext.new_submodel
                task = syskit_stub_and_deploy(component_m)
                syskit_start_execution_agents(task)

                plan.unmark_mission_task(task)
                flexmock(task).should_receive(:will_never_setup?).and_return(true)
                Runtime.update_task_states(task.plan)
                assert task.failed_to_start?
                assert_equal "#{task} reports that it cannot be configured (FATAL_ERROR ?)", task.failure_reason.original_exception.message
            end
        end
    end
end
