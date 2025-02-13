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
            end
        end
    end
end
