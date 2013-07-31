require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Composition do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel
    
    describe "#find_required_composition_child_from_role" do
        attr_reader :composition_m, :base_srv_m, :srv_m, :task_m
        before do
            @base_srv_m = Syskit::DataService.new_submodel :name => 'BaseSrv'
            @srv_m = Syskit::DataService.new_submodel :name => 'Srv'
            srv_m.provides base_srv_m
            @task_m = Syskit::TaskContext.new_submodel :name => 'Task'
            task_m.provides srv_m, :as => 'test1'
            task_m.provides srv_m, :as => 'test2'
        end
        it "returns nil for non-existent children" do
            composition_m = Syskit::Composition.new_submodel
            composition = composition_m.instanciate(plan)
            assert !composition.find_required_composition_child_from_role('bla')
        end
        it "returns the task if the composition does not require a service" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add task_m, :as => 'test'
            composition = composition_m.instanciate(plan)
            assert_equal composition.test_child, composition.find_required_composition_child_from_role('test')
        end
        it "selects the child service as the child selection specifies it" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            composition = composition_m.use('test' => task_m.test1_srv).instanciate(plan)
            assert_equal composition.test_child.test1_srv, composition.find_required_composition_child_from_role('test')
        end
        it "refines the returned service to match the composition model" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add base_srv_m, :as => 'test'
            composition = composition_m.use('test' => task_m.test1_srv).instanciate(plan)
            result = composition.find_required_composition_child_from_role('test')
            assert_equal composition.test_child.test1_srv.as(base_srv_m), result
        end
    end

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
                export task_child.out_port, :as => 'out'
                export task_child.in_port, :as => 'in'
                export srv_child.srv_out_port, :as => 'srv_out'
                export srv_child.srv_in_port, :as => 'srv_in'
                provides srv_m, :as => 'test', 'srv_out' => 'out', 'srv_in' => 'in'
            end
            @cmp = cmp_m.use('srv' => task_m).instanciate(plan)
            @task = syskit_deploy_task_context(task_m, 'task')
            @srv  = syskit_deploy_task_context(task_m, 'srv')
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
