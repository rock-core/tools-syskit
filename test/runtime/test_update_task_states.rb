require 'syskit/test/self'

module Syskit
    module Runtime
        describe ".start_task_setup" do
            let(:recorder) { flexmock }

            attr_reader :task

            before do
                task = syskit_stub_and_deploy(TaskContext.new_submodel)
                @task = flexmock(task)
            end

            describe "configuration success" do
                it "calls is_setup! if the setup is successful" do
                    promise = execution_engine.promise { recorder.called }
                    recorder.should_receive(:called).once.globally.ordered
                    task.should_receive(:setup).and_return(promise)
                    task.should_receive(:is_setup!).once.globally.ordered.pass_thru
                    promise = Runtime.start_task_setup(task)
                    assert task.setting_up?
                    assert !task.setup?
                    execution_engine.join_all_waiting_work
                    assert !task.setting_up?
                    assert task.setup?
                end
            end

            describe "configuration failure" do
                attr_reader :error_m

                before do
                    @error_m = error_m = Class.new(RuntimeError)
                    promise = execution_engine.promise { raise error_m }
                    task.should_receive(:setup).and_return(promise)
                end

                it "does not call is_setup! if the setup raises" do
                    task.should_receive(:is_setup!).never
                    Runtime.start_task_setup(task)
                    assert_raises(Roby::EmissionFailed) do
                        execution_engine.join_all_waiting_work
                    end
                    assert !task.setting_up?
                    assert !task.setup?
                end

                it "marks the underlying task as failed_to_start! if the setup raises" do
                    Runtime.start_task_setup(task)
                    assert_raises(Roby::EmissionFailed) do
                        execution_engine.join_all_waiting_work
                    end
                    assert task.failed_to_start?
                    assert_kind_of error_m, task.failure_reason.original_exception
                end
            end
        end
    end
end
