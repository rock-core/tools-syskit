# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test/execution_expectations"

module Syskit
    module Test
        describe ExecutionExpectations do
            attr_reader :task

            before do
                task_m = Syskit::RubyTaskContext.new_submodel do
                    input_port "in", "/int"
                end
                use_ruby_tasks task_m => "test", on: "stubs"
                @task = syskit_deploy_configure_and_start(task_m)
            end

            describe "#have_one_new_sample" do
                it "passes if the task emits a sample and returns it" do
                    value = expect_execution { syskit_write task.in_port, 10 }
                            .to { have_one_new_sample task.in_port }
                    assert_equal 10, value
                end
                it "fails if the task does not emit a new sample" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution
                            .timeout(0.01)
                            .to { have_one_new_sample task.in_port }
                    end
                    assert_equal "#{task.in_port} should have received 1 new "\
                                 "sample(s), but got 0",
                                 e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution
                            .timeout(0.01)
                            .to do
                                expectation = have_one_new_sample task.in_port
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
                        expect_execution
                            .timeout(0.01)
                            .to do
                                expectation = have_one_new_sample task.in_port,
                                                                  backtrace: ["bla"]
                            end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end

            describe "#have_one_new_sample_matching" do
                it "passes if the task emits a matching sample and returns it" do
                    value =
                        expect_execution { syskit_write task.in_port, 10 }
                        .to do
                            have_one_new_sample_matching(task.in_port) { |s| s == 10 }
                        end
                    assert_equal 10, value
                end
                it "fails if the task emits samples that do not match the predicate" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to { have_one_new_sample_matching(task.in_port) { false } }
                    end
                    assert_equal "#{task.in_port} should have received 1 new "\
                                 "sample(s) matching the given predicate, but got 0",
                                 e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.timeout(0.01).to do
                            expectation =
                                have_one_new_sample_matching(task.in_port) { true }
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
                        expect_execution
                            .timeout(0.01)
                            .to do
                                expectation = have_one_new_sample_matching(
                                    task.in_port, backtrace: ["bla"]
                                ) { true }
                            end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end

            describe "#have_new_samples" do
                it "passes if the task emits the required number of samples "\
                   "and returns them" do
                    value = expect_execution { syskit_write task.in_port, 10, 20 }
                            .to { have_new_samples task.in_port, 2 }
                    assert_equal [10, 20], value
                end
                it "fails if the task does not emit enough samples" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to { have_new_samples task.in_port, 2 }
                    end
                    assert_equal "#{task.in_port} should have received 2 new "\
                                 "sample(s), but got 1", e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.timeout(0.01).to do
                            expectation = have_new_samples task.in_port, 2
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
                        expect_execution.timeout(0.01).to do
                            expectation = have_new_samples(
                                task.in_port, 2, backtrace: ["bla"]
                            )
                        end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end

            describe "#have_new_samples_matching" do
                it "passes if the task emits enough matching samples and returns them" do
                    value =
                        expect_execution { syskit_write task.in_port, 1, 2, 3 }
                        .to { have_new_samples_matching(task.in_port, 2, &:odd?) }
                    assert_equal [1, 3], value
                end
                it "fails if the task does not emit enough matching samples" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 1, 2, 3 }
                            .timeout(0.01)
                            .to { have_new_samples_matching(task.in_port, 2, &:even?) }
                    end
                    assert_match "#{task.in_port} should have received 2 new "\
                                 "sample(s) matching the given predicate, "\
                                 "but got 1", e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.timeout(0.01).to do
                            expectation =
                                have_new_samples_matching(task.in_port, 2) { true }
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
                        expect_execution.timeout(0.01).to do
                            expectation = have_one_new_sample(
                                task.in_port, backtrace: ["bla"]
                            ) { true }
                        end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end

            describe "#have_no_new_sample" do
                it "validates if the task does not emit a sample" do
                    expect_execution
                        .timeout(0.01)
                        .to { have_no_new_sample task.in_port }
                end
                it "fails if the task does emit a new sample" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to { have_no_new_sample task.in_port }
                    end
                    assert_equal "#{task.in_port} should not have received a new "\
                        "sample, but it received one: 10", e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to do
                                expectation = have_no_new_sample task.in_port
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
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to do
                                expectation = have_no_new_sample task.in_port,
                                                                 backtrace: ["bla"]
                            end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end

            describe "#have_no_new_sample_matching" do
                it "validates if the task does not emit a sample" do
                    expect_execution
                        .timeout(0.01)
                        .to { have_no_new_sample task.in_port }
                end
                it "validates if the task emits samples that don't "\
                   "match the predicate" do
                    expect_execution { syskit_write task.in_port, 10 }
                        .timeout(0.01)
                        .to { have_no_new_sample_matching(task.in_port) { |s| s != 10 } }
                end
                it "fails if the task emits a sample that matches the predicate" do
                    e = assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to { have_no_new_sample_matching(task.in_port) { |s| s == 10 } }
                    end
                    assert_equal "#{task.in_port} should not have received a new sample "\
                                 "matching the given predicate, but it received one: 10",
                                 e.message.split("\n")[1]
                end
                it "provides the backtrace from the point of call by default" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to do
                                expectation = have_no_new_sample_matching(
                                    task.in_port
                                ) { true }
                            end
                    end
                    lineno = __LINE__ - 5
                    fileline = /^([^:]+):(\d+)/.match(expectation.backtrace.first)
                    assert_equal File.expand_path(__FILE__), File.expand_path(fileline[1])
                    assert_equal lineno, Integer(fileline[2])
                end
                it "allows to override the backtrace" do
                    expectation = nil
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution { syskit_write task.in_port, 10 }
                            .timeout(0.01)
                            .to do
                                expectation = have_no_new_sample(
                                    task.in_port, backtrace: ["bla"]
                                ) { true }
                            end
                    end
                    assert_equal ["bla"], expectation.backtrace
                end
            end
        end
    end
end
