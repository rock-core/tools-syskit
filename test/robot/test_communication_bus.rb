# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Robot
        describe ComBus do
            describe "#device" do
                before do
                    @bus_m = Syskit::ComBus.new_submodel(
                        name: "Combus", message_type: "/double"
                    )
                    bus_driver_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    bus_driver_m.driver_for @bus_m, as: "bus"
                    @com_bus = robot.com_bus @bus_m, as: "bus"

                    @dev_m = Syskit::Device.new_submodel name: "Device"
                    @dev_driver_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @dev_driver_m.driver_for @dev_m, as: "driver"
                end

                it "creates a device attached to a com bus" do
                    flexmock(MasterDeviceInstance)
                        .new_instances.should_receive(:attach_to)
                        .with(@com_bus, bus_to_client: true, client_to_bus: true)
                        .once
                    @com_bus.device(@dev_m, as: "dev")
                end

                it "allows to create an out-only client" do
                    flexmock(MasterDeviceInstance)
                        .new_instances.should_receive(:attach_to)
                        .with(@com_bus, bus_to_client: false, client_to_bus: true)
                        .once
                    @com_bus.device(@dev_m, as: "dev", bus_to_client: false)
                end

                it "allows to create an in-only client" do
                    flexmock(MasterDeviceInstance)
                        .new_instances.should_receive(:attach_to)
                        .with(@com_bus, bus_to_client: true, client_to_bus: false)
                        .once
                    @com_bus.device(@dev_m, as: "dev", client_to_bus: false)
                end
            end
        end
    end
end
