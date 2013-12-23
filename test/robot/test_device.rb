require 'syskit/test/self'

describe Syskit::Robot::MasterDeviceInstance do
    include Syskit::Test::Self

    attr_reader :task_m, :device_m
    attr_reader :device
    before do
        device_m = @device_m = Syskit::Device.new_submodel
        @task_m = Syskit::TaskContext.new_submodel do
            driver_for device_m, :as => 'driver'
        end
        @device = robot.device device_m, :as => 'dev'
    end

    describe "#each_fullfilled_model" do
        it "should enumerate the device's device type model as well as the submodels it provides" do
            srv_m = Syskit::DataService.new_submodel
            device_m.provides srv_m
            assert_equal [device_m, srv_m, Syskit::Device, Syskit::DataService], device.each_fullfilled_model.to_a
        end
    end

    describe "combus attachment" do
        attr_reader :combus_m, :device_m, :driver_m
        attr_reader :robot, :bus, :dev
        before do
            @device_m = Syskit::Device.new_submodel
            @combus_m = Syskit::ComBus.new_submodel :message_type => "/double"
            @robot = Syskit::Robot::RobotDefinition.new
            combus_driver_m = Syskit::TaskContext.new_submodel do
                dynamic_input_port /^w\w+$/, "/double"
                dynamic_output_port /^\w+$/, "/double"
            end
            combus_driver_m.provides combus_m, :as => 'combus_driver'
            @bus = robot.com_bus combus_m, :as => 'bus0'
            @driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for device_m, :as => 'dev_driver'
            @dev = robot.device device_m, :as => 'dev0'
        end

        describe "#attach_to" do
            it "should find combus_in_srv automatically if the task provides the requested service" do
                driver_m.orogen_model.input_port 'combus_in', '/double'
                driver_m.provides combus_m.client_in_srv, :as => 'combus_in'
                dev.attach_to(bus)

                assert_equal dev.combus_in_srv, driver_m.combus_in_srv
            end
            it "should raise if the driver has no I/O available for the combus" do
                assert_raises(ArgumentError) { dev.attach_to(bus) }
            end
        end

        describe "#attached_to?" do
            before do
                driver_m.orogen_model.input_port 'combus_in', '/double'
                driver_m.provides combus_m.client_in_srv, :as => 'combus_in'
            end

            it "should return true if the device is attached to the given combus" do
                dev.attach_to(bus)
                assert dev.attached_to?(bus)
            end
            it "should return false if the device is not attached to a combus with the given name" do
                assert !dev.attached_to?('bus0')
            end
            it "should return true if the device is not attached to the given combus" do
                assert !dev.attached_to?(bus)
            end
        end
    end

    describe "#slave" do
        it "should be able to create a slave device from a driver service slave" do
            slave_m = Syskit::DataService.new_submodel
            task_m.provides slave_m, :as => 'slave', :slave_of => task_m.driver_srv
            slave_device = device.slave 'slave'
            assert_equal device, slave_device.master_device
            assert_equal task_m.driver_srv.slave_srv, slave_device.service
        end
        it "should return existing slave devices" do
            slave_m = Syskit::DataService.new_submodel
            task_m.provides slave_m, :as => 'slave', :slave_of => task_m.driver_srv
            slave_device = device.slave 'slave'
            assert_same slave_device, device.slave('slave')
        end
    end

    describe "#method_missing" do
        it "should give access to slave devices" do
            flexmock(device).should_receive('slave').once.with('slave').and_return(obj = Object.new)
            assert_same obj, device.slave_dev
        end
    end
end

describe Syskit::Robot::SlaveDeviceInstance do
    include Syskit::Test::Self

    attr_reader :task_m, :device_m, :slave_m
    attr_reader :device, :slave_device
    before do
        device_m = @device_m = Syskit::Device.new_submodel
        slave_m = @slave_m = Syskit::DataService.new_submodel
        @task_m = Syskit::TaskContext.new_submodel do
            driver_for device_m, :as => 'driver'
            provides slave_m, :as => 'slave', :slave_of => 'driver'
        end
        @device = robot.device device_m, :as => 'dev'
        @slave_device = device.slave('slave')
    end

    describe "#each_fullfilled_model" do
        it "should enumerate the device's device type model as well as the submodels it provides" do
            srv_m = Syskit::DataService.new_submodel
            slave_m.provides srv_m
            assert_equal [slave_m, srv_m, Syskit::DataService], slave_device.each_fullfilled_model.to_a
        end
    end

end
