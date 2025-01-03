# frozen_string_literal: true

require "syskit/test/self"
require "syskit/interface/v2"

module Syskit
    module Interface
        module V2
            describe Protocol do
                before do
                    @channel = Roby::Interface::V2::Channel.new(
                        IO.pipe.last, flexmock
                    )
                    Protocol.register_marshallers(@channel)
                end

                describe Deployment do
                    before do
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

                        assert_kind_of Protocol::MasterDeviceInstance, marshalled
                        assert_equal "master_device", marshalled.name
                        assert_kind_of Protocol::DeviceModel, marshalled.model
                        assert_equal "Dev", marshalled.model.name
                    end
                end

                describe "a typelib value" do
                    before do
                        @registry = Typelib::CXXRegistry.new
                        @type = @registry.get("/uint64_t")
                    end

                    it "marshals the value and the type name" do
                        value = Typelib.from_ruby(42, @type)
                        marshalled = @channel.marshal_filter_object(value)
                        assert_equal 42, @type.from_buffer(marshalled.bytes).to_ruby
                        assert_equal "/uint64_t", marshalled.type_name
                    end
                end

                describe "a typelib registry" do
                    it "marshals the registry as XML" do
                        registry = Typelib::CXXRegistry.new
                        marshalled = @channel.marshal_filter_object(registry)
                        assert_equal marshalled.xml, registry.to_xml
                    end
                end

                it "marshals property updates" do
                    task_m = TaskContext.new_submodel do
                        property "p", "/double", 20
                    end

                    task = syskit_stub_and_deploy(
                        syskit_stub_requirements(task_m).with_conf("default")
                    )
                    plan.add_mission_task(task)
                    task.property_overrides.p = 20
                    property_time = Timecop.freeze
                    syskit_configure(task)

                    update_time = Timecop.freeze(property_time + 1)
                    task_id = task.droby_id.id
                    interface = Commands.new(flexmock(plan: plan))
                    updates = interface.poll_property_updates(task_ids: [task_id])
                    updates = @channel.marshal_filter_object(updates)

                    assert_equal update_time, updates.time
                    assert_equal 1, updates.task_updates.size

                    task_update = updates.task_updates.first
                    assert_equal task_id, task_update.id
                    assert_equal task.orocos_name, task_update.name
                    assert_equal 1, task_update.properties.size

                    update = task_update.properties.first
                    assert_equal property_time, update.time
                    assert_equal "p", update.name
                    assert_kind_of Protocol::TypelibValue, update.value
                    assert_equal "/double", update.value.type_name
                    double_t = Typelib::CXXRegistry.new.get("/double")
                    assert_equal 20, double_t.from_buffer(update.value.bytes)
                end
            end
        end
    end
end
