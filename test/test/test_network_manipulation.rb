require 'syskit/test/self'

module Syskit
    module Test
        describe NetworkManipulation do
            describe "#syskit_write" do
                before do
                    task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port 'in', '/int'
                    end
                    use_ruby_tasks task_m => 'test', on: 'stubs'
                    @task = syskit_deploy_configure_and_start(task_m)
                end
                
                it "connects and writes to the port" do
                    syskit_write @task.in_port, 10
                    assert_equal 10, @task.orocos_task.in.read_new
                end
            end
        end
    end
end
