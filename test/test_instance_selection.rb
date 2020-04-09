# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::InstanceSelection do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :stub_t, :other_stub_t
    before do
        @stub_t = stub_type "/test_t"
        @other_stub_t = stub_type "/other_test_t"
        create_simple_composition_model
    end

    describe "compute_service_selection" do
        it "should map the task to itself if the required model contains a component model" do
            assert_equal Hash[simple_component_model => simple_component_model],
                         Syskit::InstanceSelection.compute_service_selection(
                             simple_component_model.to_instance_requirements,
                             simple_component_model.to_instance_requirements, {}
                         )
        end
    end

    describe "#initialize" do
        it "should select a corresponding service in #selected if #required requires it" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, as: "test"
            end
            sel = Syskit::InstanceSelection.new(nil,
                                                component_m.to_instance_requirements,
                                                srv_m.to_instance_requirements)
            assert_equal component_m.test_srv, sel.selected.service
        end

        it "should propagate a service selection represented by 'selected' and 'required' to the mappings" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, as: "test"
            end
            sel = Syskit::InstanceSelection.new(nil,
                                                component_m.test_srv.to_instance_requirements,
                                                srv_m.to_instance_requirements)
            assert_equal component_m.test_srv,
                         sel.service_selection[srv_m]
        end

        it "should use the information present in selected and required to resolve ambiguities" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, as: "test"
                provides srv_m, as: "ambiguous"
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
        it "should return explicitly selected components represented in the instanciation plan" do
            sel = Syskit::InstanceSelection.new(c = flexmock(:fullfills? => true))
            flexmock(plan).should_receive(:[]).with(c).and_return(mapped_task = flexmock)
            assert_same mapped_task, sel.instanciate(plan)
        end
        it "should instanciate the selected requirements if no component is selected" do
            req = Syskit::InstanceRequirements.new
            flexmock(req).should_receive(:instanciate).and_return(task = Object.new)
            sel = Syskit::InstanceSelection.new(nil, flexmock(service: nil, dup: req))
            assert_same task, sel.instanciate(plan)
        end
        it "should apply the selected service on the selected component if there is one" do
            srv_m = Syskit::DataService.new_submodel
            component_m = Syskit::Component.new_submodel do
                provides srv_m, as: "test"
            end
            component = component_m.new
            sel = Syskit::InstanceSelection.new(component,
                                                component_m.test_srv.to_instance_requirements)

            assert_equal component.test_srv, sel.instanciate(plan)
        end
    end

    describe "#port_mappings" do
        it "merges the port mappings from all selected services" do
            stub_t = self.stub_t
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel { output_port "out1", other_stub_t }
            srv2_m = Syskit::DataService.new_submodel { output_port "out2", stub_t }
            proxy_task_m = Syskit::Models::Placeholder.for([srv1_m, srv2_m])
            task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out1", other_stub_t
                output_port "task_out2", stub_t
            end
            task_m.provides srv1_m, as: "test1"
            task_m.provides srv2_m, as: "test2"
            mappings = task_m.selected_for(proxy_task_m).port_mappings
            assert_equal Hash["out1" => "task_out1", "out2" => "task_out2"], mappings
        end
        it "detects colliding mappings and raises AmbiguousPortMappings" do
            stub_t = self.stub_t
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel { output_port "out", other_stub_t }
            srv2_m = Syskit::DataService.new_submodel { output_port "out", stub_t }
            proxy_task_m = Syskit::Models::Placeholder.for([srv1_m, srv2_m])
            task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out1", other_stub_t
                output_port "task_out2", stub_t
            end
            task_m.provides srv1_m, as: "test1"
            task_m.provides srv2_m, as: "test2"
            assert_raises(Syskit::AmbiguousPortMappings) do
                task_m.selected_for(proxy_task_m).port_mappings
            end
        end
        it "ignores colliding but identical mappings" do
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel { output_port "out", other_stub_t }
            srv2_m = Syskit::DataService.new_submodel { output_port "out", other_stub_t }
            proxy_task_m = Syskit::Models::Placeholder.for([srv1_m, srv2_m])
            task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out", other_stub_t
            end
            task_m.provides srv1_m, as: "test1"
            task_m.provides srv2_m, as: "test2"
            assert_equal Hash["out" => "task_out"], task_m.selected_for(proxy_task_m).port_mappings
        end
    end
end
