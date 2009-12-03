BASE_DIR = File.expand_path( '..', File.dirname(__FILE__))
$LOAD_PATH.unshift BASE_DIR
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'orocos/roby/app'
require 'orocos/roby'

APP_DIR = File.join(BASE_DIR, "test")
class TC_RobyPlugin_System < Test::Unit::TestCase
    include Orocos::RobyPlugin
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, '..', 'test', 'working_copy')

    attr_reader :sys_model
    attr_reader :orocos_engine

    def setup
        super

        @update_handler = engine.each_cycle(&Orocos::RobyPlugin.method(:update))

        FileUtils.mkdir_p Roby.app.log_dir
        @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
        ENV['PKG_CONFIG_PATH'] = File.join(WORK_DIR, "prefix", 'lib', 'pkgconfig')

        ::Orocos.initialize
        Roby.app.extend Orocos::RobyPlugin::Application
        save_collection Roby.app.loaded_orogen_projects
        save_collection Roby.app.orocos_tasks
        save_collection Roby.app.orocos_deployments

        Orocos::RobyPlugin::Application.setup
        Roby.app.orogen_load_all

        @sys_model = Orocos::RobyPlugin::SystemModel.new
        @orocos_engine    = Engine.new(plan, sys_model)
    end
    def teardown
        Roby.app.orocos_clear_models
        ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
        ::Orocos::CORBA.instance_variable_set :@loaded_toolkits, []
        ENV['PKG_CONFIG_PATH'] = @old_pkg_config

        FileUtils.rm_rf Roby.app.log_dir

        super
    end

    attr_reader :camera_driver
    attr_reader :imu_driver

    def device_tests_spec
        sys_model.device_type 'camera'
        sys_model.device_type 'imu'

        @camera_driver = Camera::Driver
        @imu_driver    = Imu::Driver
        camera_driver.driver_for 'camera'
        imu_driver.driver_for 'imu'

        orocos_engine.robot do
            device 'imu'
            device 'leftCamera',  :type => 'camera'
            device 'rightCamera', :type => 'camera'
        end
        sys_model.subsystem "ImageAcquisition" do
            add "camera", :as => 'acquisition'
            add "camera::Filter"
            autoconnect
        end
        sys_model.subsystem "Stereo" do
            add "ImageAcquisition", :as => 'image0'
            add "ImageAcquisition", :as => 'image1'
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
        assert_equal('leftCamera', left.device_name)
        assert_kind_of(camera_model, right)
        assert_equal('rightCamera', right.device_name)
    end

    def check_left_right_disambiguated_structure
        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        acquisition = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(Camera::Driver).
            with_child(Camera::Filter).to_a
        assert_equal(2, acquisition.size)

        # Both structures should be separated
        assert((acquisition[0].children.to_value_set & acquisition[1].children.to_value_set).empty?)

        # the :model flag on the dependency should be set right
        cameras = plan.find_tasks(Camera::Driver).to_a
        cameras.each do |cam|
            acq = cam.parents.first
            assert_equal(Roby.app.orocos_devices['camera'].task_model, acq[cam, TaskStructure::Dependency][:model].first)
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
            using("camera" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            using("camera" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(7, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_direct_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition").
            using("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            using("acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(7, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_indirect_disambiguation
        device_tests_spec
        orocos_engine.add("Stereo").
            using("image0.acquisition" => "leftCamera").
            using("image1.acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_instance_name_direct_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition", :as => 'leftImage').
            using("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition", :as => 'rightImage').
            using("acquisition" => "rightCamera")
        orocos_engine.add("Stereo").
            using("image0" => "leftImage").
            using("image1" => "rightImage")
        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_merge
        device_tests_spec
        sys_model.subsystem "Safety" do
            add "imu"
            add "ImageAcquisition", :as => 'image'
        end
        orocos_engine.add("Stereo").
            using("image0.acquisition" => "leftCamera").
            using("image1.acquisition" => "rightCamera")
        orocos_engine.add("Safety").
            using("image.camera" => "leftCamera")

        orocos_engine.instanciate
        # The stereo (7 tasks) is already disambiguated, but the Safety
        # subsystem should have instanciated an ImageAcquisition subsystem
        # linked to the left camera (3 tasks more).
        assert_equal(12, plan.size)

        orocos_engine.merge
        engine.garbage_collect
        assert_equal(9, plan.size)

        # Check the stereo substructure
        check_stereo_disambiguated_structure
        # Now check the safety substructure
        assert(safety = plan.find_tasks(Compositions::Safety).to_a.first)
        assert(acq    = plan.find_tasks(Compositions::ImageAcquisition).
               with_child(Camera::Driver, :device_name => 'leftCamera').to_a.first)
        assert(imu    = plan.find_tasks(Imu::Driver).to_a.first)
        assert_equal([imu, acq].to_value_set, safety.children.to_value_set)
    end
end

