# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Robot
        describe MasterDeviceInstance do
            describe "#==" do
                attr_reader :master_device, :slave_device, :device_m, :slave_device_m, :driver_m, :robot_m
                before do
                    @slave_device_m = Device.new_submodel
                    @device_m = Device.new_submodel
                    @driver_m = TaskContext.new_submodel
                    driver_m.driver_for device_m, as: "dev"
                    driver_m.driver_for slave_device_m, as: "slave", slave_of: "dev"
                    driver_m.driver_for slave_device_m, as: "other_slave", slave_of: "dev"

                    @robot_m = RobotDefinition.new
                    @master_device = robot_m.device device_m, as: "test", using: driver_m
                    @slave_device  = @master_device.slave "slave"
                end
                it "returns false for an object that is not a SlaveDeviceInstance" do
                    refute(slave_device == Object.new)
                end
                it "returns false if the underlying master device differ" do
                    other_device = robot_m.device device_m, as: "other_test", using: driver_m
                    refute(slave_device == other_device.slave("slave"))
                end
                it "returns false if it is another slave of the same master" do
                    refute(slave_device == master_device.slave("other_slave"))
                end
                it "returns if this is the same slave of the same master device" do
                    assert(slave_device == flexmock(kind_of?: true, master_device: master_device, name: slave_device.name))
                end
            end
        end
    end
end
