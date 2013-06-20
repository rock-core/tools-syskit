require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Models::CompositionChild do
    include Syskit::SelfTest
    describe "#try_resolve" do
        it "returns the composition child if it exists" do
            cmp_m = Syskit::Composition.new_submodel
            plan.add(cmp = cmp_m.new)
            task = Syskit::Component.new
            cmp.depends_on task, :role => 'task'
            child = Syskit::Models::CompositionChild.new(cmp_m, 'task')
            assert_equal task, child.try_resolve(cmp)
        end
        it "binds the found task to the expected service if there is an expected service" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel { provides(srv_m, :as => 's') }
            cmp_m  = Syskit::Composition.new_submodel do
                add srv_m, :as => 'task'
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

    describe "#connect_ports" do
        it "refuses to connect ports from different models" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, :as => 'test' }
            c1_m = Syskit::Composition.new_submodel { add srv_m, :as => 'test' }
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports c1_m.test_child, Hash.new
            end
        end
        it "gives a proper error if the connected-to object is not a composition child" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, :as => 'test' }
            other = flexmock
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports other, Hash.new
            end
        end
    end
end

