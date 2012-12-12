require 'syskit'
require 'syskit/test'

describe Syskit::Robot::RobotDefinition do
    include Syskit::SelfTest

    describe "#device" do
        attr_reader :device_m
        before do
            @device_m = Syskit::Device.new_submodel
        end

        it "creates an object of type MasterDeviceInstance by default" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            assert_kind_of Syskit::Robot::MasterDeviceInstance, robot.device(device_m, :using => driver_model, :as => 'dev')
        end
        it "registers the new device" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            device = robot.device(device_m, :using => driver_model, :as => 'dev')
            assert_same device, robot.devices['dev']
        end
        it "sets the task argument that binds the driver service to the device" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            device = robot.device(device_m, :using => driver_model, :as => 'dev')
            assert_equal Hash['dev_srv_name' => 'dev'], device.task_arguments
        end
        it "validates the given service model against Device by default" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            flexmock(device_m).should_receive(:<).with(Syskit::Device).and_return(false).once
            assert_raises(ArgumentError) do
                robot.device(device_m, :using => driver_model, :as => 'dev')
            end
        end
        it "validates the given service model using the :expected_model option" do
            expected = flexmock
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            flexmock(device_m).should_receive(:<).with(expected).and_return(false).once
            assert_raises(ArgumentError) do
                robot.device(device_m, :using => driver_model, :as => 'dev', :expected_model => expected)
            end
        end
        it "creates an object of the type given to its :class option" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            klass = flexmock
            klass.should_receive(:new).once.and_return(obj = Object.new)
            assert_same obj, robot.device(device_m, :using => driver_model, :as => 'dev', :class => klass)
        end
        it "raises if no name has been given" do
            driver_model = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            assert_raises(ArgumentError) { robot.device device_m, :using => driver_model }
        end
        it "raises if a device with the given name already exists" do
            robot.devices['dev'] = Object.new
            assert_raises(ArgumentError) do
                robot.device device_m, :as => 'dev'
            end
        end
        it "resolves the actual driver service and gives it to the device object" do
            driver_srv = flexmock(:name => 'dev_srv', :each_slave_data_service => nil)
            driver_model = flexmock { |m| m.should_receive(:find_data_service_from_type).with(device_m).and_return(driver_srv) }
            klass = flexmock { |m| m.should_receive(:new).with(any, any, any, any, driver_srv, any).once }
            robot.device device_m, :using => driver_model, :as => 'dev', :class => klass
        end
        it "registers all the slaves from the driver service" do
            driver_model = flexmock(:name => 'dev_srv')
            driver_model.should_receive(:each_slave_data_service).and_yield(flexmock(:name => 'slave'))
            master = robot.device device_m, :using => driver_model, :as => 'dev'
            assert(slave = robot.devices["dev.slave"])
            assert_same master, slave.master_device
        end
    end
end

