require 'syskit/test/self'

module Syskit
    module Test
        describe NetworkManipulation do
            describe "#syskit_write" do
                before do
                    @task_m = Syskit::RubyTaskContext.new_submodel do
                        input_port 'in', '/int'
                        output_port 'out', '/int'
                    end
                    use_ruby_tasks @task_m => 'test', on: 'stubs'
                end

                it "connects and writes to the port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    syskit_write task.in_port, 10
                    assert_equal 10, task.orocos_task.in.read_new
                end

                it "allows writing to a local port" do
                    task = syskit_deploy_configure_and_start(@task_m)
                    out_reader = task.out_port.reader
                    expect_execution.to { achieve { out_reader.ready? }}
                    sample = expect_execution { syskit_write task.out_port, 10 }.
                        to { have_one_new_sample out_reader }
                    assert_equal 10, sample
                end
            end
        end
    end
end
