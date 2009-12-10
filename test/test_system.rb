BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")
$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_System < Test::Unit::TestCase
    include RobyPluginCommonTest

    attr_reader :orocos_engine
    def setup
        super

        @orocos_engine    = Engine.new(plan, sys_model)
    end

    attr_reader :can_bus
    attr_reader :imu_driver
    attr_reader :camera_driver
    attr_reader :motors
    attr_reader :controldev

    def test_simple_composition_instanciation
        subsys_model = sys_model.subsystem "simple" do
            add 'simple_source::source', :as => 'source'
            add 'simple_sink::sink', :as => 'sink'
            autoconnect

            add "echo::Echo"
            add "echo::Echo", :as => 'echo'
            add "echo::Echo", :as => :echo
        end

        subsys_model.compute_autoconnection
        assert_equal([ [["source", "sink"], [["cycle", "cycle", Hash.new]]] ].to_set,
            subsys_model.connections.to_set)

        subsys_task = subsys_model.instanciate(orocos_engine)
        assert_kind_of(subsys_model, subsys_task)

        children = subsys_task.each_child.to_a
        assert_equal(4, children.size)

        echo1, echo2 = plan.find_tasks(Echo::Echo).to_a
        assert(echo1)
        assert(echo2)
        source = plan.find_tasks(SimpleSource::Source).to_a.first
        assert(source)
        sink   = plan.find_tasks(SimpleSink::Sink).to_a.first
        assert(sink)

        echo_roles = [echo1, echo2].
            map do |child_task|
                info = subsys_task[child_task, TaskStructure::Dependency]
                info[:roles]
            end
        assert_equal([['echo'].to_set, [].to_set].to_set, 
                     echo_roles.to_set)

        assert_equal(['source'].to_set, subsys_task[source, TaskStructure::Dependency][:roles])
        assert_equal(['sink'].to_set, subsys_task[sink, TaskStructure::Dependency][:roles])

        assert_equal([ [source, sink, [["cycle", "cycle", Hash.new]]] ].to_set,
            Flows::DataFlow.enum_for(:each_edge).to_set)
    end

    def test_robot_device_definition
        sys_model.device_type 'stereo', :interface => SystemTest::Stereo
        sys_model.device_type 'camera', :interface => SystemTest::CameraDriver
        stereo_model = SystemTest::Stereo
        stereo_model.data_source 'stereo'

        stereo_driver = SystemTest::StereoCamera
        stereo_driver.driver_for 'stereo'
        stereo_driver.data_source 'camera', :as => 'left',  :slave_of => 'stereo'
        stereo_driver.data_source 'camera', :as => 'right', :slave_of => 'stereo'

        orocos_engine.robot do
            device 'stereo',  :as => 'frontStereo'
        end
        
        driver_task = orocos_engine.robot.devices['frontStereo']
        assert_kind_of stereo_driver, driver_task

        camera_type = Roby.app.orocos_data_sources['camera']
        assert_kind_of camera_type, orocos_engine.robot.devices['frontStereo.left']
        assert_kind_of camera_type, orocos_engine.robot.devices['frontStereo.right']
    end

    def device_tests_spec
        sys_model.bus_type 'can'
        sys_model.device_type 'camera',          :interface => "system_test::CameraDriver"
        sys_model.device_type 'stereo',          :interface => "system_test::Stereo"
        sys_model.device_type 'imu',             :interface => "system_test::IMU"
        sys_model.device_type 'motors',          :interface => "system_test::MotorController"
        sys_model.device_type 'control_devices', :interface => "system_test::ControlDevices"

        @can_bus        = SystemTest::CanBus
        can_bus.driver_for 'can', :message_type => 'can/Message'
        @imu_driver     = SystemTest::IMU
        imu_driver.driver_for 'imu'
        @camera_driver = SystemTest::CameraDriver
        camera_driver.driver_for 'camera'
        @motors         = SystemTest::MotorController
        motors.driver_for 'motors'
        @controldev     = SystemTest::ControlDevices
        controldev.driver_for 'control_devices'

        orocos_engine.robot do
            device 'imu'
            device 'camera',  :as => 'leftCamera'
            device :camera,   :as => :rightCamera

            com_bus 'can', :as => 'can0'
            through 'can0' do
                device 'control_devices'
                device 'motors'
            end
        end
        sys_model.subsystem "ImageAcquisition" do
            data_source "camera"
            add "camera", :as => 'acquisition'
            add "system_test::CameraFilter"
            autoconnect
        end
        sys_model.subsystem "Stereo" do
            data_source 'stereo'
            stereo = add "system_test::StereoProcessing", :as => 'processing'
            image0 = add "camera", :as => "image0"
            image1 = add "camera", :as => "image1"
            connect image0.image => stereo.image0
            connect image1.image => stereo.image1
        end
    end

    def test_device_definition
        device_tests_spec
        assert(camera_model = Roby.app.orocos_devices['camera'])

        robot = orocos_engine.robot
        left  = robot.devices['leftCamera']
        right = robot.devices['rightCamera']
        assert(left != right)
        assert_kind_of(camera_model, left)
        assert_equal('leftCamera', left.camera_name)
        assert_kind_of(camera_model, right)
        assert_equal('rightCamera', right.camera_name)
    end

    def check_left_right_disambiguated_structure
        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        acquisition = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::CameraDriver).
            with_child(SystemTest::CameraFilter).to_a
        assert_equal(2, acquisition.size)

        # Both structures should be separated
        assert((acquisition[0].children.to_value_set & acquisition[1].children.to_value_set).empty?)

        # the :model flag on the dependency should be set right
        cameras = plan.find_tasks(SystemTest::CameraDriver).to_a
        cameras.each do |cam|
            acq = cam.parents.first
            assert_equal(Roby.app.orocos_devices['camera'], acq[cam, TaskStructure::Dependency][:model].first)
        end
        return acquisition
    end

    def check_stereo_disambiguated_structure
        acquisition = check_left_right_disambiguated_structure
        assert(stereo = plan.find_tasks(Compositions::Stereo).to_a.first)

        assert_equal(acquisition.to_value_set, stereo.children.to_value_set)
    end

    def test_device_model_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition").
            use("camera" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            use("camera" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(10, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_direct_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition").
            use("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            use("acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(10, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_indirect_disambiguation
        device_tests_spec
        orocos_engine.add("Stereo").
            use("image0.acquisition" => "leftCamera").
            use("image1.acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(11, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_instance_name_direct_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition", :as => 'leftImage').
            use("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition", :as => 'rightImage').
            use("acquisition" => "rightCamera")
        orocos_engine.add("Stereo").
            use("image0" => "leftImage").
            use("image1" => "rightImage")
        orocos_engine.instanciate

        assert_equal(11, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_merge
        device_tests_spec
        sys_model.subsystem "Safety" do
            add "imu"
            add "ImageAcquisition", :as => 'image'
        end
        orocos_engine.add("Stereo").
            use("image0" => :ImageAcquisition).
            use("image1" => "ImageAcquisition").
            use("image0.acquisition" => "leftCamera").
            use("image1.acquisition" => "rightCamera")
        orocos_engine.add("Safety").
            use("image.camera" => "leftCamera")

        orocos_engine.instanciate
        # The stereo (7 tasks) is already disambiguated, but the Safety
        # subsystem should have instanciated an ImageAcquisition subsystem
        # linked to the left camera (3 tasks more).
        assert_equal(16, plan.size)

        orocos_engine.merge
        engine.garbage_collect
        assert_equal(13, plan.size)

        # Check the stereo substructure
        check_stereo_disambiguated_structure
        # Now check the safety substructure
        safety_tasks = plan.find_tasks(Compositions::Safety).to_a
        acq_tasks    = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::CameraDriver, :camera_name => 'leftCamera').to_a
        imu_tasks    = plan.find_tasks(SystemTest::IMU).to_a

        assert_equal(1, safety_tasks.size)
        assert_equal(1, acq_tasks.size)
        assert_equal(1, imu_tasks.size)

        safety = safety_tasks.first
        acq    = acq_tasks.first
        imu    = imu_tasks.first
        assert_equal([imu, acq].to_value_set, safety.children.to_value_set)
    end

    def test_select_slave_data_source
        sys_model.device_type 'stereo', :interface => SystemTest::Stereo
        sys_model.device_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_source 'camera', :as => 'image0', :slave_of => 'stereo'
            data_source 'camera', :as => 'image1', :slave_of => 'stereo'
        end

        sys_model.subsystem "ImageAcquisition" do
            add "system_test::CameraFilter"
            add "camera"
        end

        orocos_engine.robot do
            device "stereo", :as => 'front_stereo'
        end
        orocos_engine.add("ImageAcquisition").
            use("camera" => "front_stereo.image0")

        orocos_engine.instanciate

        assert_equal(3, plan.size)
        root_tasks = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::StereoCamera, :stereo_name => "front_stereo").
            with_child(SystemTest::CameraFilter).to_a
        assert_equal(1, root_tasks.size)
    end

    def test_demultiplexing
        self.event_logger = true
        sys_model.device_type 'stereo', :interface => SystemTest::Stereo
        sys_model.device_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_source 'camera', :as => 'image0', :slave_of => 'stereo'
            data_source 'camera', :as => 'image1', :slave_of => 'stereo'
        end
        SystemTest::CameraDriver.driver_for 'camera'

        sys_model.subsystem "Stereo" do
            data_source 'stereo'
            stereo = add "system_test::StereoProcessing", :as => 'processing'
            image0 = add "camera", :as => "image0"
            image1 = add "camera", :as => "image1"
            connect image0.image => stereo.image0
            connect image1.image => stereo.image1
        end

        sys_model.subsystem "StereoComparison" do
            add "stereo", :as => "stereo0"
            add "stereo", :as => "stereo1"
        end

        dev_stereo, dev_left_camera, dev_right_camera = nil
        orocos_engine.robot do
            dev_stereo       = device 'stereo', :as => 'front_stereo'
            dev_left_camera  = device 'camera', :as => 'left_camera'
            dev_right_camera = device 'camera', :as => 'right_camera'
        end
        root_task = orocos_engine.add("StereoComparison")

        # Try to instanciate without disambiguation. This should fail miserably
        assert(3, plan.size)
        assert_raises(Ambiguous) { orocos_engine.instanciate }
        assert(3, plan.size)

        # Add disambiguation information and reinstanciate
        root_task.use("image0" => "left_camera").
            use("image1" => "right_camera").
            use("stereo0" => Compositions::Stereo).
            use("stereo1" => "front_stereo")

        orocos_engine.instanciate

        # Two cameras, a stereocamera, a stereoprocessing, a Stereo composition
        # and a StereoComparison composition => 6 tasks
        assert_equal(6, plan.size)

        # Check the structure
        root_tasks = plan.find_tasks(Compositions::StereoComparison).
            with_child(Compositions::Stereo).
            with_child(SystemTest::StereoCamera).to_a
        assert_equal(1, root_tasks.size)

        plan.each_task do |task|
            puts "#{task} #{task.model} #{task.children.map(&:to_s)}"
        end
    end

    def test_provides
        sys_model.device_type 'camera'
        sys_model.device_type 'stereoCamera'

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereoCamera'
            subdevice 'leftCamera',  :type => 'camera'
            subdevice 'rightCamera', :type => 'camera'
        end
        Compositions::Stereo.class_eval do
            data_source "stereoCamera"
        end
    end


    def test_driver_for_multiple_devices
        SystemTest::StereoCamera.multiplexed_driver 'joystick', 'sliderbox'
    end

    def test_communication_busses
        device_tests_spec

        assert_equal 'can0', orocos_engine.robot.devices['motors'].com_bus
        assert_equal 'can0', orocos_engine.robot.devices['control_devices'].com_bus

        orocos_engine.link_to_busses
        tasks = plan.find_tasks(SystemTest::MotorController).
            with_child(orocos_engine.robot.devices['can0'], :device_name => 'can0')
        assert_equal(1, tasks.to_a.size)
    end
end

