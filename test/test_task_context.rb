require 'syskit/test'

describe Syskit::TaskContext do
    include Syskit::SelfTest
    describe "#find_input_port" do
        attr_reader :task
        before do
            @task = stub_roby_task_context do
                input_port "in", "int"
                output_port "out", "int"
            end
        end

        it "should return the port from #orocos_task if it exists" do
            assert_equal task.orocos_task.port("in"), task.find_input_port("in").to_orocos_port
        end
        it "should return nil for an output port" do
            assert_equal nil, task.find_input_port("out")
        end
        it "should return nil for a port that does not exist" do
            assert_equal nil, task.find_input_port("does_not_exist")
        end
    end

    describe "#find_output_port" do
        attr_reader :task
        before do
            @task = stub_roby_task_context do
                input_port "in", "int"
                output_port "out", "int"
            end
        end

        it "should return the port from #orocos_task if it exists" do
            assert_equal task.orocos_task.port("out"), task.find_output_port("out").to_orocos_port
        end
        it "should return nil for an input port" do
            assert_equal nil, task.find_output_port("in")
        end
        it "should return nil for a port that does not exist" do
            assert_equal nil, task.find_output_port("does_not_exist")
        end
    end
end

