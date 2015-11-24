require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::Models::CompositionChild do
    describe "#try_resolve" do
        it "returns the composition child if it exists" do
            task_m = Syskit::Component.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: 'task'
            plan.add(cmp = cmp_m.instanciate(plan))
            assert_equal cmp.task_child, cmp_m.task_child.try_resolve(cmp)
        end
        it "binds the found task to the expected service if there is an expected service" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel { provides(srv_m, as: 's') }
            cmp_m  = Syskit::Composition.new_submodel do
                add srv_m, as: 'task'
            end
            cmp = cmp_m.instanciate(plan, Syskit::DependencyInjectionContext.new('task' => task_m))
            assert_kind_of task_m, cmp.task_child
            assert_equal task_m.s_srv.bind(cmp.task_child), cmp_m.task_child.try_resolve(cmp)
        end
        it "returns nil if the composition child does not exist" do
            cmp_m = Syskit::Composition.new_submodel
            cmp = cmp_m.new
            child = Syskit::Models::CompositionChild.new(cmp_m, 'task')
            assert_equal nil, child.try_resolve(cmp)
        end
    end

    describe "#resolve" do
        let(:child_m) do
            task_m = Syskit::Component.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: 'task'
        end

        it "resolves the task with try_resolve" do
            flexmock(child_m).should_receive(:try_resolve).
                with(root = flexmock).and_return(result = flexmock)
            assert_equal result, child_m.resolve(root)
        end
        it "raises ArgumentError if the task cannot be resolved" do
            flexmock(child_m).should_receive(:try_resolve).
                with(root = flexmock).and_return(nil)
            assert_raises(ArgumentError) { child_m.resolve(root) }
        end
    end

    describe "#connect_ports" do
        it "refuses to connect ports from different models" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, as: 'test' }
            c1_m = Syskit::Composition.new_submodel { add srv_m, as: 'test' }
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports c1_m.test_child, Hash.new
            end
        end
        it "gives a proper error if the connected-to object is not a composition child" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, as: 'test' }
            other = flexmock
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports other, Hash.new
            end
        end
    end

    describe "#connect_to" do
        it "can connect to a specific service on the output side" do
            srv_in_m = Syskit::DataService.new_submodel do
                input_port 'in', '/double'
            end
            task_in_m = Syskit::TaskContext.new_submodel do
                input_port 'in0', '/double'
                input_port 'in1', '/double'
                provides srv_in_m, as: 'test', 'in' => 'in0'
            end
            srv_out_m = Syskit::DataService.new_submodel do
                output_port 'out', '/double'
            end
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_out_m, as: 'out'
            cmp_m.add task_in_m, as: 'in'
            cmp_m.out_child.connect_to cmp_m.in_child.test_srv

            expected = Hash[
                ['out', 'in'] => {['out', 'in0'] => Hash.new}
            ]
            assert_equal expected, cmp_m.connections
        end
        it "can connect from a specific service on the input side" do
            srv_in_m = Syskit::DataService.new_submodel do
                input_port 'in', '/double'
            end
            srv_out_m = Syskit::DataService.new_submodel do
                output_port 'out', '/double'
            end
            task_out_m = Syskit::TaskContext.new_submodel do
                output_port 'out0', '/double'
                output_port 'out1', '/double'
                provides srv_out_m, as: 'test', 'out' => 'out0'
            end
            cmp_m = Syskit::Composition.new_submodel do
                add srv_in_m, as: 'in'
                add task_out_m, as: 'out'
                out_child.test_srv.connect_to in_child
            end

            expected = Hash[
                ['out', 'in'] => {['out0', 'in'] => Hash.new}
            ]
            assert_equal expected, cmp_m.connections
        end
    end

    describe "#bind" do
        it "should resolve services based on the initial selection" do
            srv_m = Syskit::DataService.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: 'test'
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: 'test0'
            task_m.provides srv_m, as: 'test1'
            cmp = cmp_m.use('test' => task_m.test0_srv).instanciate(plan)
            assert_equal cmp.test_child.test0_srv, cmp_m.test_child.bind(cmp.test_child)
        end
        it "should be able to resolve child-of-child" do
            srv_m = Syskit::DataService.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            child_cmp_m = Syskit::Composition.new_submodel
            cmp_m.add child_cmp_m, as: 'test'
            child_cmp_m.add srv_m, as: 'test'
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: 'test0'
            task_m.provides srv_m, as: 'test1'
            cmp = cmp_m.use('test' => child_cmp_m.use('test' => task_m.test0_srv)).instanciate(plan)
            assert_equal cmp.test_child.test_child.test0_srv, cmp_m.test_child.test_child.bind(cmp.test_child.test_child)
        end
    end
    
    describe "as hash keys" do
        it "is not the same than another child with the same model" do
            composition_m = Syskit::Composition.new_submodel
            srv_m = Syskit::DataService.new_submodel
            test1 = composition_m.add srv_m, as: 'test1'
            test2 = composition_m.add srv_m, as: 'test2'
            assert !Hash[test1 => 10].has_key?(test2)
        end
    end
end

describe Syskit::Models::InvalidCompositionChildPort do
    attr_reader :cmp_m
    before do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
            output_port 'out', '/double'
        end
        @cmp_m = Syskit::Composition.new_submodel
        cmp_m.add task_m, as: 'test'
    end

    it "can be pretty-printed" do
        e = Syskit::Models::InvalidCompositionChildPort.new(cmp_m, 'test', 'bla')
        PP.pp(e, "")
    end
end


