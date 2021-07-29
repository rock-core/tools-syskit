# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Runtime
        describe ".update_task_states" do
            attr_reader :task
            before do
                task_m = Syskit::TaskContext.new_submodel
                @task = syskit_stub_and_deploy(task_m)
            end

            it "does not process finished tasks" do
                syskit_configure_and_start(task)
                syskit_stop(task)

                flexmock(Syskit::Runtime)
                    .should_receive(:handle_single_task_state_update)
                    .never
                Syskit::Runtime.update_task_states(plan)
            end

            it "does not process tasks that failed to start" do
                expect_execution do
                    task.failed_to_start!(RuntimeError.exception("something"))
                end.to { fail_to_start task }

                flexmock(Syskit::Runtime)
                    .should_receive(:handle_single_task_state_update)
                    .never
                Syskit::Runtime.update_task_states(plan)
            end

            it "does not try to reconfigure a task that failed to start" do
                def task.configure
                    raise "fail to configure"
                end

                expect_execution.scheduler(true).to { fail_to_start task }
                flexmock(task).should_receive(:setup).never
                Syskit::Runtime.update_task_states(plan)
            end

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

            describe "when the task will never setup" do
                attr_reader :task
                before do
                    component_m = Syskit::TaskContext.new_submodel
                    task = syskit_stub_and_deploy(component_m)
                    syskit_start_execution_agents(task)

                    plan.unmark_mission_task(task)
                    flexmock(task).should_receive(:will_never_setup?).once.and_return(true)
                    @task = task
                end

                it "attempts to kill it and does nothing further if that succeeds" do
                    task.should_receive(:kill_execution_agent_if_alone).pass_thru
                    expect_execution.scheduler(true).to { achieve { task.execution_agent.finishing? } }
                end
                it "marks the task as failed-to-start if the execution agent cannot be killed" do
                    task.should_receive(:kill_execution_agent_if_alone).and_return(false)
                    failure_reason = expect_execution { Runtime.update_task_states(plan) }
                                     .scheduler(true)
                                     .to { fail_to_start task }
                    assert_equal "#{task} reports that it cannot be configured (FATAL_ERROR ?)",
                                 failure_reason.original_exception.message
                end
            end
        end
    end
end
