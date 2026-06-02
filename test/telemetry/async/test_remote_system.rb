# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"
require "syskit/interface/v2"

module Syskit
    module Telemetry
        module Async
            describe RemoteSystem do
                before do
                    @remote_system = RemoteSystem.new
                end

                describe "orogen model registration" do
                    it "reconstructs the states" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.states.push(
                            ["error_custom", :error],
                            ["exception_custom", :exception],
                            ["fatal_custom", :fatal],
                            ["runtime_custom", :runtime]
                        )
                        sysdef = protocol::SystemDefinitions.new(
                            orogen_models: [protocol_m],
                            registry: Typelib::CXXRegistry.new.to_xml
                        )

                        @remote_system.update_from_protocol(sysdef)
                        spec = @remote_system.find_task_model_from_name("bla::A")
                        assert_kind_of OroGen::Spec::TaskContext, spec

                        expected = [
                            ["INIT", :toplevel],
                            ["PRE_OPERATIONAL", :toplevel],
                            ["FATAL_ERROR", :toplevel],
                            ["EXCEPTION", :toplevel],
                            ["STOPPED", :toplevel],
                            ["RUNNING", :toplevel],
                            ["RUNTIME_ERROR", :toplevel],
                            ["error_custom", :error],
                            ["exception_custom", :exception],
                            ["fatal_custom", :fatal],
                            ["runtime_custom", :runtime]
                        ]

                        assert_equal expected, spec.each_state.to_a
                    end

                    it "reconstructs the properties" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.properties << protocol::OroGenPropertyModel.new(
                            name: "p", type_name: "/double"
                        )
                        spec = rebuild_task_context_orogen_model(protocol_m)
                               .find_property("p")
                        assert_kind_of OroGen::Spec::Property, spec
                        assert_equal "p", spec.name
                        assert_equal @remote_system.type_from_name("/double"), spec.type
                    end

                    it "reconstructs the attributes" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.attributes << protocol::OroGenAttributeModel.new(
                            name: "a", type_name: "/float"
                        )
                        spec = rebuild_task_context_orogen_model(protocol_m)
                               .find_attribute("a")
                        assert_kind_of OroGen::Spec::Attribute, spec
                        assert_equal "a", spec.name
                        assert_equal @remote_system.type_from_name("/float"), spec.type
                    end

                    it "reconstructs the input ports" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.ports << protocol::OroGenPortModel.new(
                            name: "p", type_name: "/int32_t", input: true
                        )
                        spec = rebuild_task_context_orogen_model(protocol_m)
                               .find_input_port("p")
                        assert_kind_of OroGen::Spec::InputPort, spec
                        assert_equal "p", spec.name
                        assert_equal @remote_system.type_from_name("/int32_t"), spec.type
                    end

                    it "reconstructs the output ports" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.ports << protocol::OroGenPortModel.new(
                            name: "p", type_name: "/int64_t", input: false
                        )

                        spec = rebuild_task_context_orogen_model(protocol_m)
                               .find_output_port("p")
                        assert_kind_of OroGen::Spec::OutputPort, spec
                        assert_equal "p", spec.name
                        assert_equal @remote_system.type_from_name("/int64_t"), spec.type
                    end

                    it "reconstructs the dynamic input ports" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.dynamic_ports << protocol::OroGenDynamicPortModel.new(
                            name_pattern: /p/, type_name: "/int32_t", input: true
                        )
                        spec = rebuild_task_context_orogen_model(protocol_m)
                        type = @remote_system.type_from_name("/int32_t")
                        spec = spec.find_dynamic_input_ports("p", type)
                        assert_equal 1, spec.size
                        spec = spec.first
                        assert_kind_of OroGen::Spec::DynamicInputPort, spec
                        assert_equal(/p/, spec.name)
                        assert_equal type, spec.type
                    end

                    it "reconstructs the dynamic output ports" do
                        protocol_m = create_basic_protocol_model("bla::A", "bla")
                        protocol_m.dynamic_ports << protocol::OroGenDynamicPortModel.new(
                            name_pattern: /p/, type_name: "/int32_t", input: false
                        )
                        spec = rebuild_task_context_orogen_model(protocol_m)
                        type = @remote_system.type_from_name("/int32_t")
                        spec = spec.find_dynamic_output_ports("p", type)
                        assert_equal 1, spec.size
                        spec = spec.first
                        assert_kind_of OroGen::Spec::DynamicOutputPort, spec
                        assert_equal(/p/, spec.name)
                        assert_equal type, spec.type
                    end

                    def toplevel_states
                        [
                            ["INIT", :toplevel],
                            ["PRE_OPERATIONAL", :toplevel],
                            ["FATAL_ERROR", :toplevel],
                            ["EXCEPTION", :toplevel],
                            ["STOPPED", :toplevel],
                            ["RUNNING", :toplevel],
                            ["RUNTIME_ERROR", :toplevel]
                        ]
                    end

                    def rebuild_task_context_orogen_model(protocol_m)
                        sysdef = protocol::SystemDefinitions.new(
                            orogen_models: [protocol_m],
                            registry: Typelib::CXXRegistry.new.to_xml
                        )

                        @remote_system.update_from_protocol(sysdef)
                        @remote_system.find_task_model_from_name(protocol_m.name)
                    end

                    def create_basic_protocol_model(name, project_name)
                        m = protocol::OroGenModel.new(
                            name: name, project_name: project_name,
                            states: toplevel_states, properties: [], attributes: [],
                            dynamic_ports: [], ports: []
                        )
                        m.ports << protocol::OroGenPortModel.new(
                            name: "state", type_name: "/int32_t", input: false
                        )
                        m
                    end

                    def protocol
                        Interface::V2::Protocol
                    end
                end
            end
        end
    end
end
