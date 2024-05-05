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

            it "warns about receiving too many state changes" do
                syskit_configure_and_start(@task)

                state_changes = %I[RUNNING RUNTIME_ERROR] *
                                Deployment::STATE_READER_BUFFER_SIZE
                expected = []
                expected <<
                    "got #{state_changes.size} state updates for #{@task}, we might "\
                    "have lost some state updates in the process. Received:"
                state_changes.each { |s| expected << "  #{s}" }

                flexmock(@task).should_receive(:update_orogen_state)
                               .and_return { state_changes.shift }
                messages = []
                flexmock(Runtime)
                    .should_receive(:warn)
                    .and_return { |msg| messages << msg }

                Runtime.handle_task_runtime_states(@task)
                assert_equal expected, messages
            end
        end
    end
end
