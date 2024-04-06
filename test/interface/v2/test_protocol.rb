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
            end
        end
    end
end
