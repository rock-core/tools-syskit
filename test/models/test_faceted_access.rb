# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Models::FacetedAccess do
    attr_reader :srv_m, :task_m, :sub_task_m, :facet, :stub_t, :other_stub_t
    before do
        @stub_t = stub_t = stub_type "/test_t"
        @other_stub_t = other_stub_t = stub_type "/other_test_t"
        @srv_m = Syskit::DataService.new_submodel do
            output_port "d", other_stub_t
        end
        @task_m = Syskit::TaskContext.new_submodel do
            output_port "i", stub_t
        end
        @sub_task_m = task_m.new_submodel do
            output_port "sd", other_stub_t
        end
        sub_task_m.provides srv_m, as: "test"

        @facet = Syskit::Models::FacetedAccess.new(
            sub_task_m, Syskit::Models::Placeholder.for([task_m, srv_m])
        )
    end

    describe "#find_ports_on_required" do
        it "should list all ports with the required name, pointing to the corresponding facet model" do
            assert_equal [srv_m.d_port], facet.find_ports_on_required("d")
            assert_equal [task_m.i_port], facet.find_ports_on_required("i")
            assert_equal [], facet.find_ports_on_required("sd")
        end
    end

    describe "#find_all_port_mappings_for" do
        it "should return the port on the final object model" do
            assert_equal [sub_task_m.sd_port].to_set,
                         facet.find_all_port_mappings_for("d")
            assert_equal [sub_task_m.i_port].to_set,
                         facet.find_all_port_mappings_for("i")
        end

        it "should return an empty set if the port does not exist on the facet" do
            assert_equal Set.new, facet.find_all_port_mappings_for("sd")
        end

        it "should return a set of unique ports" do
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel do
                output_port "d", other_stub_t
            end
            sub_task_m.provides srv1_m, as: "test1"
            facet = Syskit::Models::FacetedAccess.new(sub_task_m, Syskit::Models::Placeholder.for([srv1_m, srv_m]))
            assert_equal [sub_task_m.sd_port].to_set,
                         facet.find_all_port_mappings_for("d")
        end
        it "should return more than one port if the name is used multiple times on the input and candidates are mapped to different ports on the final model" do
            stub_t = self.stub_t
            srv1_m = Syskit::DataService.new_submodel do
                output_port "d", stub_t
            end
            sub_task_m.provides srv1_m, as: "test1"
            facet = Syskit::Models::FacetedAccess.new(sub_task_m, Syskit::Models::Placeholder.for([srv1_m, srv_m]))
            assert_equal [sub_task_m.sd_port, sub_task_m.i_port].to_set,
                         facet.find_all_port_mappings_for("d")
        end
    end

    describe "#find_port" do
        it "should return a port on the facet" do
            p = facet.find_port("d")
            assert_equal "d", p.name
            assert_equal facet, p.component_model
        end

        it "should return nil if the port does not exist on the facet" do
            assert !facet.find_port("sd")
        end

        it "should return a port if it exists multiple times and all the candidates map one single port on the final object" do
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel do
                output_port "d", other_stub_t
            end
            sub_task_m.provides srv1_m, as: "test1"
            facet = Syskit::Models::FacetedAccess.new(sub_task_m, Syskit::Models::Placeholder.for([srv1_m, srv_m]))

            p = facet.find_port("d")
            assert "d", p.name
            assert facet, p.component_model
        end

        it "should raise AmbiguousPortOnCompositeModel if the port exists multiple times on the fact, but maps to more than one port on the final object" do
            stub_t = self.stub_t
            srv1_m = Syskit::DataService.new_submodel do
                output_port "d", stub_t
            end
            sub_task_m.provides srv1_m, as: "test1"
            facet = Syskit::Models::FacetedAccess.new(sub_task_m, Syskit::Models::Placeholder.for([srv1_m, srv_m]))
            assert_raises(Syskit::AmbiguousPortOnCompositeModel) do
                facet.find_port("d")
            end
            # Try a second time to make sure the caching mechanism works
            assert_raises(Syskit::AmbiguousPortOnCompositeModel) do
                facet.find_port("d")
            end
        end
    end

    describe "#self_port_to_component_port" do
        it "should resolve the port on the object" do
            assert_equal sub_task_m.sd_port, facet.find_port("d").to_component_port
            assert_equal sub_task_m.i_port,  facet.find_port("i").to_component_port
        end

        it "should be able to resolve if the port exists multiple times on the fact and all the candidates map one single port on the final object" do
            other_stub_t = self.other_stub_t
            srv1_m = Syskit::DataService.new_submodel do
                output_port "d", other_stub_t
            end
            sub_task_m.provides srv1_m, as: "test1"
            facet = Syskit::Models::FacetedAccess.new(sub_task_m, Syskit::Models::Placeholder.for([srv1_m, srv_m]))
            assert_equal sub_task_m.sd_port, facet.find_port("d").to_component_port
        end
    end

    describe "#connect_to" do
        it "should be usable as argument to Syskit.connect" do
            other_stub_t = self.other_stub_t
            in_srv_m = Syskit::DataService.new_submodel do
                input_port "in", other_stub_t
            end
            in_task_m = Syskit::TaskContext.new_submodel do
                input_port "task_in", other_stub_t
            end
            in_task_m.provides in_srv_m, as: "test"
            out_srv_m = Syskit::DataService.new_submodel do
                output_port "out", other_stub_t
            end
            out_task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out", other_stub_t
            end
            out_task_m.provides out_srv_m, as: "test"

            cmp_m = Syskit::Composition.new_submodel do
                add out_task_m, as: "out"
                add in_task_m, as: "in"
            end
            cmp_m.out_child.as(out_srv_m).connect_to cmp_m.in_child.as(in_srv_m)
        end
    end
end
