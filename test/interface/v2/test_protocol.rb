# frozen_string_literal: true

require "syskit/test/self"
require "syskit/interface/v2"
require "roby/interface/v2"
require "syskit/interface/v2/protocol"

module Syskit
    module Interface
        module V2
            describe Protocol do
                before do
                    @io_r, @io_w = Socket.pair(:UNIX, :STREAM, 0)
                    @server = Roby::Interface::V2::Channel.new(@io_w, false)
                    Protocol.register_marshallers(@server)
                    @client = Roby::Interface::V2::Channel.new(@io_r, true)
                end

                describe "marshalling of Syskit::Deployment" do
                    before do
                        deployment_m = Syskit::Deployment.new_submodel
                        @deployment = deployment_m.new(
                            process_name: "test", spawn_options: { some: "options" }
                        )
                    end

                    it "is marshalled as if a standard Roby task" do
                        marshalled = assert_transmits(@deployment)

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
                        marshalled = assert_transmits(@deployment)

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

                describe "marshalling of a Syskit::TaskContext model" do
                    it "transmits a task context model" do
                        task_m = Syskit::TaskContext.new_submodel(name: "SomeModel") do
                            property "p", "/int32_t"
                            input_port "in", "/float"
                            output_port "out", "/double"
                        end

                        ret = assert_transmits(task_m)
                        assert_equal "SomeModel", ret.orogen_model_name
                        assert_equal %w[p], ret.properties.map(&:name)
                        assert_equal(%w[/int32_t], ret.properties.map { |p| p.type.name })

                        ports = ret.ports.sort_by(&:name)
                        assert_equal %w[in out state], ports.map(&:name)
                        assert_equal(%w[/float /double /int32_t],
                                     ports.map { |p| p.type.name })
                        assert_equal [true, false, false], ports.map(&:input?)
                    end
                end

                def assert_transmits(object)
                    @server.write_packet(object)
                    @client.read_packet
                end
            end
        end
    end
end
