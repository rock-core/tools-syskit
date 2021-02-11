# frozen_string_literal: true

module Syskit
    module Fixtures
        module SimpleCompositionModel
            attr_reader :simple_service_model
            attr_reader :simple_component_model
            attr_reader :simple_task_model
            attr_reader :simple_composition_model

            def create_simple_composition_model
                stub_t = self.stub_t
                srv = @simple_service_model = DataService.new_submodel(name: "SimpleServiceModel") do
                    input_port "srv_in", stub_t
                    output_port "srv_out", stub_t
                end
                @simple_component_model = TaskContext.new_submodel(name: "SimpleComponentModel") do
                    input_port "in", stub_t
                    output_port "out", stub_t
                end
                simple_component_model.provides(
                    simple_service_model,
                    { "srv_in" => "in", "srv_out" => "out" },
                    as: "srv"
                )
                @simple_task_model = TaskContext.new_submodel(name: "SimpleTaskModel") do
                    input_port "in", stub_t
                    output_port "out", stub_t
                end
                simple_task_model.provides(
                    simple_service_model,
                    { "srv_in" => "in", "srv_out" => "out" },
                    as: "srv"
                )
                @simple_composition_model = Composition.new_submodel(name: "SimpleCompositionModel") do
                    add srv, as: "srv"
                    add srv, as: "srv2"
                    connect srv_child => srv2_child
                    export srv_child.srv_in_port
                    export srv_child.srv_out_port
                    provides srv, as: "srv"
                end

                [simple_service_model, simple_component_model, simple_task_model, simple_composition_model]
            end
        end
    end
end
