require 'syskit/test/self'

module Syskit
    module Runtime
        describe ".start_task_setup" do
            let(:recorder) { flexmock }
            it "calls is_setup! if the setup is successful" do
                task = syskit_stub_and_deploy(TaskContext.new_submodel)
                task = flexmock(task)

                promise = execution_engine.promise { recorder.called }
                recorder.should_receive(:called).once.ordered
                task.should_receive(:setup).and_return(promise)
                task.should_receive(:is_setup!).once.ordered.pass_thru
                promise = Runtime.start_task_setup(task)
                assert task.setting_up?
                assert !task.setup?
                execution_engine.join_all_waiting_work
                assert !task.setting_up?
                assert task.setup?
            end

            it "does not call is_setup! if the setup raises" do
                task = syskit_stub_and_deploy(TaskContext.new_submodel)
                task = flexmock(task)

                promise = execution_engine.promise { raise ArgumentError }
                task.should_receive(:setup).and_return(promise)
                task.should_receive(:is_setup!).never
                promise = Runtime.start_task_setup(task)
                execution_engine.join_all_waiting_work
                assert !task.setting_up?
                assert !task.setup?
            end
        end
    end
end
