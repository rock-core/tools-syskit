require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Composition do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    describe "port access" do
        attr_reader :task, :cmp, :srv
        before do
            srv_m = Syskit::DataService.new_submodel(:name => "Srv") do
                output_port "srv_out", "/double"
                input_port "srv_in", "/double"
            end
            task_m = Syskit::TaskContext.new_submodel(:name => "Task") do
                output_port "out", "/double"
                input_port "in", "/double"
                provides srv_m, :as => 'srv'
            end
            cmp_m = Syskit::Composition.new_submodel(:name => "Cmp") do
                add task_m, :as => 'task'
                add srv_m, :as => 'srv'
                export task.out_port, :as => 'out'
                export task.in_port, :as => 'in'
                export srv.srv_out_port, :as => 'srv_out'
                export srv.srv_in_port, :as => 'srv_in'
                provides srv_m, :as => 'test', 'srv_out' => 'out', 'srv_in' => 'in'
            end
            @cmp = cmp_m.use('srv' => task_m).instanciate(syskit_engine)
            @task = stub_roby_task_context('task', task_m)
            @srv  = stub_roby_task_context('srv', task_m)
            plan.replace_task(cmp.child_from_role('task'), task)
            plan.replace_task(cmp.child_from_role('srv'), srv)
        end

        it "an exported input can be resolved from a task" do
            assert_equal task.orocos_task.port("in"),
                cmp.find_input_port("in").to_orocos_port
        end
        it "an exported input port can be resolved from a data service" do
            assert_equal task.orocos_task.port("in"),
                cmp.test_srv.find_input_port("srv_in").to_orocos_port
        end
        it "an input port exported from a data service can be resolved to the selected task" do
            assert_equal srv.orocos_task.port("in"),
                cmp.find_input_port("srv_in").to_orocos_port
        end
        it "an exported output can be resolved from a task" do
            assert_equal task.orocos_task.port("out"),
                cmp.find_output_port("out").to_orocos_port
        end
        it "an exported output port can be resolved from a data service" do
            assert_equal task.orocos_task.port("out"),
                cmp.test_srv.find_output_port("srv_out").to_orocos_port
        end
        it "an output port exported from a data service can be resolved to the selected task" do
            assert_equal srv.orocos_task.port("out"),
                cmp.find_output_port("srv_out").to_orocos_port
        end
    end
end
