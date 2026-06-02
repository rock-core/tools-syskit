# frozen_string_literal: true

require "syskit/test/self"
require "syskit/interface/v2"

module Syskit
    module Interface
        module V2
            module Protocol
                describe Deployment do
                    before do
                        @channel = Roby::Interface::V2::Channel.new(
                            IO.pipe.last, flexmock
                        )
                        Protocol.register_marshallers(@channel)

                        deployment_m = Syskit::Deployment.new_submodel
                        @deployment = deployment_m.new(
                            process_name: "test", spawn_options: { some: "options" }
                        )
                    end

                    it "is marshalled as if a standard Roby task" do
                        marshalled = @channel.marshal_filter_object(@deployment)

                        assert_equal "test", marshalled.arguments[:process_name]
                        assert_equal @deployment.droby_id.id, marshalled.id
                    end

                    it "adds deployment-specific info" do
                        flexmock(@deployment, pid: 200)
                        handles = {
                            "test" => Syskit::Deployment::RemoteTaskHandles.new(
                                flexmock(
                                    ior: "some_ior",
                                    model: flexmock(name: "orogen::Name")
                                )
                            )
                        }
                        flexmock(@deployment, remote_task_handles: handles)
                        marshalled = @channel.marshal_filter_object(@deployment)

                        assert_equal 200, marshalled.pid

                        expected_task = {
                            name: "test",
                            ior: "some_ior",
                            orogen_model_name: "orogen::Name"
                        }
                        assert_equal [expected_task],
                                     marshalled.deployed_tasks.map(&:to_h)
                    end
                end

                describe "Device support" do
                    before do
                        @channel = Roby::Interface::V2::Channel.new(
                            IO.pipe.last, flexmock
                        )
                        Protocol.register_marshallers(@channel)

                        @device_m = Syskit::Device.new_submodel(name: "Dev")
                        @driver_m = Syskit::TaskContext.new_submodel
                        @driver_m.driver_for @device_m, as: "driver"

                        profile = Actions::Profile.new("Test")
                        @robot = profile.robot
                    end

                    it "marshals a master device" do
                        @robot.device @device_m, as: "master_device"
                        marshalled = @channel.marshal_filter_object(
                            @robot.master_device_dev
                        )

                        assert_kind_of MasterDeviceInstance, marshalled
                        assert_equal "master_device", marshalled.name
                        assert_kind_of DeviceModel, marshalled.model
                        assert_equal "Dev", marshalled.model.name
                    end
                end

                describe "typelib registry support" do
                    it "transmits the registry as XML" do
                        registry = Typelib::CXXRegistry.new
                        marshalled = Protocol.marshal_typelib_registry(registry)

                        assert_equal marshalled.xml, registry.to_xml
                    end
                end

                describe "orogen model support" do
                    it "transmits the state symbols" do
                        project = OroGen::Spec::Project.new(OroGen::Loaders::RTT.new)
                        model = OroGen::Spec::TaskContext.new(project, "A")
                        model.runtime_states "runtime_custom"
                        model.error_states "error_custom"
                        model.exception_states "exception_custom"
                        model.fatal_states "fatal_custom"

                        marshalled = Protocol.marshal_orogen_model(model)

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
                        assert_equal expected, marshalled.states
                    end

                    it "marshals the model and its elements" do
                        project = OroGen::Spec::Project.blank
                        project.name "bla"
                        registry = Typelib::CXXRegistry.new
                        registry.each(with_aliases: false) do
                            project.loader.register_type_model(_1, true)
                        end
                        model = OroGen::Spec::TaskContext.new(project, "A")
                        model.attribute "a", "/int64_t"
                        model.property "p", "/int8_t"
                        model.input_port "in", "/int16_t"
                        model.output_port "out", "/int32_t"
                        model.dynamic_input_port(/i/, "/float")
                        model.dynamic_output_port(/o/, "/double")

                        marshalled = Protocol.marshal_orogen_model(model)

                        assert_equal "A", marshalled.name
                        assert_equal "bla", marshalled.project_name

                        ports = marshalled.ports.map { _1.to_h }
                        assert_equal(
                            Set[{ name: "in", type_name: "/int16_t", input: true },
                                { name: "out", type_name: "/int32_t", input: false }],
                            ports.to_set
                        )

                        dynamic_ports = marshalled.dynamic_ports.map { _1.to_h }
                        assert_equal(
                            Set[
                                { name_pattern: /i/, type_name: "/float", input: true },
                                { name_pattern: /o/, type_name: "/double", input: false }
                            ],
                            dynamic_ports.to_set
                        )

                        properties = marshalled.properties.map { _1.to_h }
                        assert_equal([{ name: "p", type_name: "/int8_t" }], properties)

                        attributes = marshalled.attributes.map { _1.to_h }
                        assert_equal([{ name: "a", type_name: "/int64_t" }], attributes)
                    end
                end
            end
        end
    end
end
