require 'syskit'
require 'syskit/test'

describe Syskit::Device do
    include Syskit::SelfTest

    attr_reader :task_m, :device_m, :devices
    before do
        @task_m = Syskit::TaskContext.new_submodel
        @device_m = Syskit::Device.new_submodel
        @devices = Hash.new
        robot = flexmock(:devices => devices)
        flexmock(task_m).new_instances.should_receive(:robot).and_return(robot)
    end
    
    def register_device(name)
        @devices[name] = flexmock(name, :name => name)
    end

    describe "#find_device_attached_to" do
        attr_reader :dev0
        before do
            task_m.driver_for device_m, :as => 'dev0'
            @dev0 = register_device 'DEV0'
        end
        it "should resolve the device attached using a service name" do
            task = task_m.new "dev0_name" => 'DEV0'
            assert_equal dev0, task.find_device_attached_to('dev0')
        end
        it "should resolve the device attached using a data service bound to the task instance" do
            task = task_m.new "dev0_name" => 'DEV0'
            assert_equal dev0, task.find_device_attached_to(task.dev0_srv)
        end
        it "should resolve the device attached using a data service bound to the task model" do
            task = task_m.new "dev0_name" => 'DEV0'
            assert_equal dev0, task.find_device_attached_to(task_m.dev0_srv)
        end
        it "should return nil for services that are not yet attached to a device" do
            task = task_m.new
            assert !task.find_device_attached_to('dev0')
        end
        it "should raise if a device name is invalid" do
            task = task_m.new "dev0_name" => 'BLA'
            assert_raises(Syskit::SpecError) { task.each_master_device.to_a }
        end
    end

    describe "#each_master_device" do
        attr_reader :dev0, :dev1
        before do
            task_m.driver_for device_m, :as => 'dev0'
            task_m.driver_for device_m, :as => 'dev1'
            @dev0 = register_device 'DEV0'
            @dev1 = register_device 'DEV1'
        end
        it "should map the driver services to the actual devices using #find_device_attached_to" do
            task = task_m.new "dev0_name" => 'DEV0', 'dev1_name' => 'DEV1'
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev0_srv).once.and_return(dev0)
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev1_srv).once.and_return(dev1)
            assert_equal [dev0, dev1].to_set, task.each_master_device.to_set
        end
        it "should yield a given device only once" do
            task = task_m.new "dev0_name" => 'DEV0', 'dev1_name' => 'DEV0'
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev0_srv).once.and_return(dev0)
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev1_srv).once.and_return(dev0)
            assert_equal [dev0], task.each_master_device.to_a
        end
    end
end

describe Syskit::ComBus do
    include Syskit::SelfTest

    attr_reader :task_m, :combus_m, :devices
    before do
        @task_m = Syskit::TaskContext.new_submodel
        combus_m = @combus_m = Syskit::ComBus.new_submodel
        device_m = @device_m = Syskit::Device.new_submodel
        robot do
            com_bus combus_m, :as => 'COM', 'combus'
            device device_m, :as => 'DEV', :attach_to => 'combus'
        end
    end
    describe "#each_attached_device" do
        combus_task = TaskContext.new_submodel { provides combus_m, :as => 'com' }.new('com_name' => 'COM')
        device_task = TaskContext.new_submodel { provides device_m, :as => 'dev' }.new('dev_name' => 'DEV')
        assert_equal [device_task], combus_task.each_attached_device.to_a
    end
    describe "#each_device_connection" do
    end
end

