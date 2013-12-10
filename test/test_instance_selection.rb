require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceSelection do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
    end

    describe "compute_service_selection" do
        it "should map the task to itself if the required model contains a component model" do
            assert_equal Hash[simple_component_model => simple_component_model],
                Syskit::InstanceSelection.compute_service_selection(
                    simple_component_model.to_instance_requirements,
                    simple_component_model.to_instance_requirements, Hash.new)
        end
    end

    describe "#initialize" do
        it "should select a corresponding service in #selected if #required requires it" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, :as => 'test'
            end
            sel = Syskit::InstanceSelection.new(nil,
                component_m.to_instance_requirements,
                srv_m.to_instance_requirements)
            assert_equal component_m.test_srv, sel.selected.service
        end

        it "should propagate a service selection represented by 'selected' and 'required' to the mappings" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, :as => 'test'
            end
            sel = Syskit::InstanceSelection.new(nil,
                component_m.test_srv.to_instance_requirements,
                srv_m.to_instance_requirements)
            assert_equal component_m.test_srv,
                sel.service_selection[srv_m]
        end
    end

    describe "instanciate" do
        it "should return a selected component within the given plan" do
            plan.add(task = Roby::Task.new)
            sel = Syskit::InstanceSelection.new(task)
            plan.in_transaction do |trsc|
                assert_same trsc[task], sel.instanciate(trsc)
            end
        end
        it "should return the component if one is selected" do
            sel = Syskit::InstanceSelection.new(c = flexmock(:fullfills? => true))
            assert_same c, sel.instanciate(plan)
        end
        it "should instanciate the selected requirements if no component is selected" do
            req = Syskit::InstanceRequirements.new
            flexmock(req).should_receive(:instanciate).and_return(task = Object.new)
            sel = Syskit::InstanceSelection.new(nil, flexmock(:dup => req))
            assert_same task, sel.instanciate(plan)
        end
        it "should apply the selected service on the selected component if there is one" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, :as => 'test'
            end
            component = component_m.new
            sel = Syskit::InstanceSelection.new(component,
                component_m.test_srv.to_instance_requirements)

            assert_equal component.test_srv, sel.instanciate(plan)
        end
    end
end


