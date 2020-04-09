# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::DependencyInjectionContext do
    describe "#push" do
        it "applies explicit choices recursively layer-by-layer" do
            srv0 = Syskit::DataService.new_submodel
            task0 = Syskit::TaskContext.new_submodel { provides srv0, as: "test" }
            di0 = Syskit::DependencyInjection.new
            di0.add(srv0 => task0)
            di1 = Syskit::DependencyInjection.new
            di1.add("name" => srv0)

            context = Syskit::DependencyInjectionContext.new
            context.push di0
            context.push di1
            assert_equal task0.test_srv, context.current_state.explicit["name"]
        end

        it "applies default choices recursively layer-by-layer" do
            srv0 = Syskit::DataService.new_submodel
            task0 = Syskit::TaskContext.new_submodel { provides srv0, as: "test" }
            di0 = Syskit::DependencyInjection.new
            di0.add(srv0 => task0)
            di1 = Syskit::DependencyInjection.new
            di1.add(srv0)

            context = Syskit::DependencyInjectionContext.new
            context.push di0
            context.push di1
            assert_equal task0.test_srv, context.current_state.explicit[srv0]
        end

        it "allows to add barriers on name-to-selection mapping to avoid recursive name-based selection" do
            srv0 = Syskit::DataService.new_submodel
            task0 = Syskit::TaskContext.new_submodel(name: "T0") { provides srv0, as: "test" }
            task1 = Syskit::TaskContext.new_submodel(name: "T1") { provides srv0, as: "test" }
            di0 = Syskit::DependencyInjection.new
            di0.add("child" => task1, srv0 => task0)
            di1 = Syskit::DependencyInjection.new
            di1.add_mask(["child"])

            context = Syskit::DependencyInjectionContext.new
            context.push di0
            context.push di1

            _, component_model, service_selection, used_objects =
                context.selection_for("child", srv0.to_instance_requirements)
            assert_equal task0, component_model.model
        end
    end
end
