require 'syskit/test/self'
require 'syskit/test/execution_expectations'

module Syskit
    module Test
        describe ExecutionExpectations do
            attr_reader :task

            before do
                task_m = Syskit::RubyTaskContext.new_submodel do
                    input_port 'in', '/int'
                    output_port 'out', '/int'

                    poll do
                        Orocos.allow_blocking_calls do
                            if sample = orocos_task.in.read_new
                                orocos_task.out.write(sample)
                            end
                        end
                    end
                end
                use_ruby_tasks task_m => 'test', on: 'stubs'
                @task = syskit_deploy_configure_and_start(task_m)
            end

            describe "#have_one_new_sample" do
                it "passes if the task emits a sample and returns it" do
                    value = expect_execution { syskit_write task.in_port, 10 }.
                        to { have_one_new_sample task.out_port }
                    assert_equal 10, value
                end
                it "fails if the task does not emit a new sample" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.
                            timeout(0.01).
                            to { have_one_new_sample task.out_port }
                    end
                    assert_equal "#{task.out_port} should have received a new sample",
                        e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.
                            timeout(0.01).
                            to do
                                expectation = have_one_new_sample task.out_port
                            end
                    end
                    lineno = __LINE__ - 3
                    fileline = /^([^:]+):(\d+)/.match(expectation.backtrace.first)
                    assert_equal File.expand_path(__FILE__), File.expand_path(fileline[1])
                    assert_equal lineno, Integer(fileline[2])
                end
                it "allows to override the backtrace" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.
                            timeout(0.01).
                            to do
                                expectation = have_one_new_sample task.out_port,
                                    backtrace: ['bla']
                            end
                    end
                    assert_equal ['bla'], expectation.backtrace
                end
            end

            describe "#have_no_new_sample" do
                it "validates if the task does not emit a sample" do
                    expect_execution.
                        timeout(0.01).
                        to { have_no_new_sample task.out_port }
                end
                it "fails if the task does emit a new sample" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }.
                            timeout(0.01).
                            to { have_no_new_sample task.out_port }
                    end
                    assert_equal "#{task.out_port} should not have received a new "\
                        "sample, but it received one: 10", e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }.
                            timeout(0.01).
                            to do
                                expectation = have_no_new_sample task.out_port
                            end
                    end
                    lineno = __LINE__ - 3
                    fileline = /^([^:]+):(\d+)/.match(expectation.backtrace.first)
                    assert_equal File.expand_path(__FILE__), File.expand_path(fileline[1])
                    assert_equal lineno, Integer(fileline[2])
                end
                it "allows to override the backtrace" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }.
                            timeout(0.01).
                            to do
                                expectation = have_no_new_sample task.out_port,
                                    backtrace: ['bla']
                            end
                    end
                    assert_equal ['bla'], expectation.backtrace
                end
            end
        end
    end
end
