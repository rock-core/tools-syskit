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
    
    describe "#find_device_attached_to" do
        attr_reader :dev0
        before do
            task_m.driver_for device_m, :as => 'dev0'
            @dev0 = robot.device device_m, :as => 'DEV0'
        end
        it "should resolve the device attached using a service name" do
            task = task_m.new "dev0_dev" => dev0
            assert_equal dev0, task.find_device_attached_to('dev0')
        end
        it "should resolve the device attached using a data service bound to the task instance" do
            task = task_m.new "dev0_dev" => dev0
            assert_equal dev0, task.find_device_attached_to(task.dev0_srv)
        end
        it "should resolve the device attached using a data service bound to the task model" do
            task = task_m.new "dev0_dev" => dev0
            assert_equal dev0, task.find_device_attached_to(task_m.dev0_srv)
        end
        it "should return nil for services that are not yet attached to a device" do
            task = task_m.new
            assert !task.find_device_attached_to('dev0')
        end
    end

    describe "#each_master_device" do
        attr_reader :dev0, :dev1
        before do
            task_m.driver_for device_m, :as => 'dev0'
            task_m.driver_for device_m, :as => 'dev1'
            @dev0 = robot.device device_m, :as => 'DEV0', :using => task_m.dev0_srv
            @dev1 = robot.device device_m, :as => 'DEV1', :using => task_m.dev1_srv
        end
        it "should map the driver services to the actual devices using #find_device_attached_to" do
            task = task_m.new "dev0_dev" => dev0, 'dev1_dev' => dev1
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev0_srv).once.and_return(dev0)
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev1_srv).once.and_return(dev1)
            assert_equal [dev0, dev1].to_set, task.each_master_device.to_set
        end
        it "should yield a given device only once" do
            task = task_m.new "dev0_dev" => dev0, 'dev1_dev' => dev0
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev0_srv).once.and_return(dev0)
            flexmock(task).should_receive(:find_device_attached_to).with(task_m.dev1_srv).once.and_return(dev0)
            assert_equal [dev0], task.each_master_device.to_a
        end
    end
end

describe Syskit::ComBus do
    include Syskit::SelfTest

    attr_reader :device_driver_m, :combus_driver_m, :combus_m, :combus, :device, :device_m
    before do
        combus_m = @combus_m = Syskit::ComBus.new_submodel(:message_type => '/double')
        device_m = @device_m = Syskit::Device.new_submodel
        @device_driver_m = Syskit::TaskContext.new_submodel do
            input_port 'from_bus', '/double'
            output_port 'to_bus', '/double'
            driver_for device_m, :as => 'dev'
            provides combus_m.client_srv, :as => 'combus_client'
        end
        @combus_driver_m = Syskit::TaskContext.new_submodel do
            dynamic_input_port /^w\w+$/, '/double'
            dynamic_output_port /^\w+$/, '/double'
            driver_for combus_m, :as => 'com'
        end
        @combus = robot.com_bus combus_m, :as => 'COM'
        @device = robot.device(device_m, :as => 'DEV').
            attach_to(robot.COM_dev)
    end
    describe "#each_com_bus_device" do
        it "lists the combus devices the task is driving" do
            plan.add(combus_task = combus_driver_m.new('com_dev' => combus))
            combus_task.each_com_bus_device.to_a
            assert_equal [robot.devices['COM']], combus_task.each_com_bus_device.to_a
        end
    end
    describe "#attached_to?" do
        it "returns true if the device is attached to the bus" do
            assert device.attached_to?(combus)
        end
        it "returns false if the device is not attached to any bus" do
            device = robot.device device_m, :as => 'other_device'
            assert !device.attached_to?(combus)
        end
        it "returns false if the device is attached to a different bus" do
            other_bus = robot.com_bus combus_m, :as => 'other_bus'
            assert !device.attached_to?(other_bus)
        end
    end
    describe "#each_attached_device" do
        it "can list the devices attached to the combus" do
            plan.add(combus_task = combus_driver_m.new('com_dev' => combus))
            plan.add(device_task = device_driver_m.new('dev_dev' => device))
            assert_equal [device], combus_task.each_attached_device.to_a
        end
    end
    describe "#attach" do
        attr_reader :combus_task, :device_task
        before do
            plan.add(@combus_task = combus_driver_m.new('com_dev' => combus))
            plan.add(@device_task = device_driver_m.new('dev_dev' => device))
            flexmock(combus_m).should_receive(:dynamic_service_name).and_return('dyn_srv')
        end
        it "creates a service on the combus task" do
            srv = combus_task.require_dynamic_service('com_bus', :as => 'DEV', :direction => 'inout')
            flexmock(combus_task).should_receive(:require_dynamic_service).
                with('dyn_srv', :as => 'DEV', :direction => 'inout').once.and_return(srv)
            combus_task.attach(device_task)
        end
        it "does not create an input service on the combus task if the device does not have an output service" do
            srv = combus_task.require_dynamic_service('com_bus', :as => 'DEV', :direction => 'out')
            flexmock(device).should_receive(:combus_out_srv)
            flexmock(combus_task).should_receive(:require_dynamic_service).
                with('dyn_srv', :as => 'DEV', :direction => 'out').once.and_return(srv)
            combus_task.attach(device_task)
        end
        it "does not create an output service on the combus task if the device does not have an input service" do
            srv = combus_task.require_dynamic_service('com_bus', :as => 'DEV', :direction => 'in')
            flexmock(device).should_receive(:combus_in_srv)
            flexmock(combus_task).should_receive(:require_dynamic_service).
                with('dyn_srv', :as => 'DEV', :direction => 'in').once.and_return(srv)
            combus_task.attach(device_task)
        end
        it "ignores devices that are not attached to the bus" do
            flexmock(device).should_receive(:attached_to?).with(combus).and_return(false).once
            flexmock(combus_task).should_receive(:require_dynamic_service).never
            combus_task.attach(device_task)
        end
        it "connects the combus output service to the client input service" do
        end
        it "connects the combus input service to the client output service" do
        end
        it "ignores com bus driver services that are not tied to an actual device" do
        end
    end
end

