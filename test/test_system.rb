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
        assert_equal([ [["source", "sink"], {["cycle", "cycle"] => Hash.new}] ].to_set,
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

        assert_equal([ [source, sink, {["cycle", "cycle"] => Hash.new}] ].to_set,
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

    def complete_robot_definition
        orocos_engine.robot do
            device 'imu'
            device 'camera',  :as => 'leftCamera'
            device :camera,   :as => :rightCamera

            com_bus 'can', :as => 'can0'
            through 'can0' do
                device 'joystick'
                device 'sliderbox'
                device 'motors'
            end
        end
    end

    def complete_system_model
        sys_model.bus_type 'can'
        sys_model.device_type 'camera',    :interface => SystemTest::CameraDriver
        sys_model.device_type 'stereo',    :interface => SystemTest::Stereo
        sys_model.device_type 'imu',       :interface => SystemTest::IMU
        sys_model.device_type 'motors',    :interface => SystemTest::MotorController
        sys_model.device_type 'joystick',  :interface => SystemTest::Joystick
        sys_model.device_type 'sliderbox', :interface => SystemTest::Sliderbox

        @can_bus        = SystemTest::CanBus
        can_bus.driver_for 'can', :message_type => 'can/Message'
        @camera_driver  = SystemTest::CameraDriver
        camera_driver.driver_for 'camera'
        @imu_driver     = SystemTest::IMU
        imu_driver.driver_for 'imu'
        @motors         = SystemTest::MotorController
        motors.driver_for 'motors'
        @controldev     = SystemTest::ControlDevices
        controldev.driver_for 'sliderbox'
        controldev.driver_for 'joystick'

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
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end
    end

    def test_device_definition
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => "leftCamera"
            device "camera", :as => "rightCamera"
        end

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
            assert_equal(Roby.app.orocos_data_sources['camera'], acq[cam, TaskStructure::Dependency][:model].first)
        end
        return acquisition
    end

    def check_stereo_disambiguated_structure
        acquisition = check_left_right_disambiguated_structure
        assert(stereo = plan.find_tasks(Compositions::Stereo).to_a.first)

        stereo_processing = plan.find_tasks(SystemTest::StereoProcessing).to_value_set
        assert_equal(acquisition.to_value_set | stereo_processing, stereo.children.to_value_set)
    end

    def test_device_model_disambiguation
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => "leftCamera"
            device "camera", :as => "rightCamera"
        end
        orocos_engine.add("ImageAcquisition").
            use("camera" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            use("camera" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(6, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_direct_disambiguation
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => "leftCamera"
            device "camera", :as => "rightCamera"
        end
        orocos_engine.add("ImageAcquisition").
            use("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            use("acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(6, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_indirect_disambiguation
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => "leftCamera"
            device "camera", :as => "rightCamera"
        end
        orocos_engine.add("Stereo").
            use("image0" => "ImageAcquisition").
            use("image1" => "ImageAcquisition").
            use("image0.acquisition" => "leftCamera").
            use("image1.acquisition" => "rightCamera")

        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_instance_name_direct_disambiguation
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => 'leftCamera'
            device 'camera', :as => 'rightCamera'
        end
        orocos_engine.add("ImageAcquisition", :as => 'leftImage').
            use("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition", :as => 'rightImage').
            use("acquisition" => "rightCamera")
        orocos_engine.add("Stereo").
            use("image0" => "leftImage").
            use("image1" => "rightImage")
        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_merge
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => 'leftCamera'
            device 'camera', :as => 'rightCamera'
            device 'imu'
        end

        sys_model.subsystem "Safety" do
            add "imu"
            add "ImageAcquisition", :as => 'image'
        end
        orocos_engine.add("Stereo").
            use("image0" => :ImageAcquisition).
            use("image1" => "ImageAcquisition").
            use("image0.camera" => "leftCamera").
            use("image1.camera" => "rightCamera")
        orocos_engine.add("Safety").
            use("camera" => "leftCamera")

        orocos_engine.instanciate
        # The stereo (7 tasks) is already disambiguated, but the Safety
        # subsystem should have instanciated an ImageAcquisition subsystem
        # linked to the left camera (3 tasks more).
        assert_equal(13, plan.size)

        orocos_engine.merge
        engine.garbage_collect
        assert_equal(10, plan.size)

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
            data_source 'camera', :as => 'left', :slave_of => 'stereo'
            data_source 'camera', :as => 'right', :slave_of => 'stereo'
        end

        sys_model.subsystem "ImageAcquisition" do
            add "system_test::CameraFilter"
            add "camera"
        end

        orocos_engine.robot do
            device "stereo", :as => 'front_stereo'
        end
        orocos_engine.add("ImageAcquisition").
            use("camera" => "front_stereo.left")

        orocos_engine.instanciate

        assert_equal(3, plan.size)
        root_tasks = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::StereoCamera, :stereo_name => "front_stereo").
            with_child(SystemTest::CameraFilter).to_a
        assert_equal(1, root_tasks.size)
    end

    def test_failed_resolve_does_not_impact_the_plan
        sys_model.device_type 'stereo', :interface => SystemTest::Stereo
        sys_model.device_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_source 'camera', :as => 'left', :slave_of => 'stereo'
            data_source 'camera', :as => 'right', :slave_of => 'stereo'
        end
        SystemTest::CameraDriver.driver_for 'camera'

        sys_model.subsystem "Stereo" do
            data_source 'stereo'
            stereo = add "system_test::StereoProcessing", :as => 'processing'
            image0 = add "camera", :as => "image0"
            image1 = add "camera", :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end

        sys_model.subsystem "StereoComparison" do
            add "stereo", :as => "stereo0"
            add "stereo", :as => "stereo1"
        end

        dev_stereo = nil
        orocos_engine.robot do
            dev_stereo       = device 'stereo', :as => 'front_stereo'
        end
        root_task = orocos_engine.add("StereoComparison")

        # Try to instanciate without disambiguation. This should fail miserably
        assert_equal(1, plan.size)
        assert_raises(Ambiguous) { orocos_engine.resolve }
        assert_equal(1, plan.size)
    end

    def test_port_mapping_at_instanciation_time
        sys_model.device_type 'stereo', :interface => SystemTest::Stereo
        sys_model.device_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_source 'camera', :as => 'left', :slave_of => 'stereo'
            data_source 'camera', :as => 'right', :slave_of => 'stereo'
        end
        SystemTest::CameraDriver.driver_for 'camera'

        sys_model.subsystem "Stereo" do
            data_source 'stereo'
            stereo = add "system_test::StereoProcessing", :as => 'processing'
            image0 = add "camera", :as => "image0"
            image1 = add "camera", :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end

        sys_model.subsystem "StereoComparison" do
            add "stereo", :as => "stereo0"
            add "stereo", :as => "stereo1"
        end

        dev_stereo = nil
        orocos_engine.robot do
            dev_stereo       = device 'stereo', :as => 'front_stereo'
        end

        # We compare the stereovision engine on the stereocamera with our own
        # algorithm by instanciating the stereocamera directly, and using its
        # cameras to inject into the Stereo composition.
        root_task = orocos_engine.add("StereoComparison").
            use('stereo0' => 'front_stereo').
            use('stereo1' => 'Stereo').
            use('stereo1.image0'  => 'front_stereo.left').
            use('stereo1.image1'  => 'front_stereo.right')

        # Add disambiguation information and reinstanciate
        orocos_engine.resolve

        # A stereocamera, a stereoprocessing, a Stereo composition
        # and a StereoComparison composition => 4 tasks
        assert_equal(4, plan.size)

        # Check the dependency structure
        tasks = plan.find_tasks(Compositions::StereoComparison).
            with_child(Compositions::Stereo).
            with_child(SystemTest::StereoCamera).to_a
        assert_equal(1, tasks.size)

        tasks = plan.find_tasks(Compositions::Stereo).
            with_child(SystemTest::StereoCamera, :roles => ['image0', 'image1'].to_set).
            to_a
        assert_equal(1, tasks.size)

        # Check the data flow
        expected_connections = {
            ['rightImage', 'rightImage'] => {:type => :data, :lock => :lock_free, :pull => false, :init => false},
            ['leftImage', 'leftImage']   => {:type => :data, :lock => :lock_free, :pull => false, :init => false}
        }

        tasks = plan.find_tasks(SystemTest::StereoCamera).
            with_child( SystemTest::StereoProcessing, Flows::DataFlow, expected_connections ).
            to_a
        assert_equal(1, tasks.size)
    end

    def test_device_merging
        complete_system_model
        orocos_engine.robot do
            device "joystick"
            device "sliderbox"

            com_bus "can", :as => "can0"
            through "can0" do
                device "joystick", :as => "joystick1"
                device "sliderbox", :as => "sliderbox1"
            end

            com_bus "can", :as => "can1"
            through "can1" do
                device "sliderbox", :as => "sliderbox2"
            end
        end
        orocos_engine.instanciate
        assert_equal 7, plan.size

        joystick   = orocos_engine.tasks['joystick']
        joystick1  = orocos_engine.tasks['joystick1']
        sliderbox  = orocos_engine.tasks['sliderbox']
        sliderbox1 = orocos_engine.tasks['sliderbox1']
        sliderbox2 = orocos_engine.tasks['sliderbox2']

        assert(joystick.can_merge?(sliderbox))
        assert(sliderbox.can_merge?(joystick))
        assert(joystick1.can_merge?(sliderbox1))
        assert(sliderbox1.can_merge?(joystick1))
        assert(!sliderbox.can_merge?(sliderbox2))
        assert(!sliderbox1.can_merge?(sliderbox2))
        assert(!joystick.can_merge?(sliderbox2))
        assert(!joystick1.can_merge?(sliderbox2))

        orocos_engine.merge
        engine.garbage_collect
        assert_equal 5, plan.size
    end

    def test_communication_busses
        complete_system_model
        complete_robot_definition

        assert_equal 'can0', orocos_engine.robot.devices['motors'].com_bus
        assert_equal 'can0', orocos_engine.robot.devices['joystick'].com_bus
        assert_equal 'can0', orocos_engine.robot.devices['sliderbox'].com_bus

        orocos_engine.instanciate
        orocos_engine.merge
        orocos_engine.link_to_busses
        engine.garbage_collect

        tasks = plan.find_tasks(SystemTest::MotorController).
            with_child(orocos_engine.robot.devices['can0']).to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::MotorController).
            with_child(orocos_engine.robot.devices['can0'], Flows::DataFlow, ['can_out', 'motorsw'] => Hash.new).
            with_parent(orocos_engine.robot.devices['can0'], Flows::DataFlow, ['motors', 'can_in'] => Hash.new).
            to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::ControlDevices).
            with_child(orocos_engine.robot.devices['can0']).to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::ControlDevices).
            with_parent(orocos_engine.robot.devices['can0'], Flows::DataFlow,
                        ['joystick', 'can_in_joystick'] => Hash.new,
                        ['sliderbox', 'can_in_sliderbox'] => Hash.new).
            to_a
        assert_equal(1, tasks.to_a.size)
    end
end

