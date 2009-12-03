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

    # For now, cheat big time ;-)
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

    def test_device_model_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition").
            using("camera" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            using("camera" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(7, plan.size)

        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        acquisition = plan.find_tasks(ImageAcquisition).
            with_child(Camera::Driver).
            with_child(Camera::Filter).to_a
        assert_equal(2, acquisition.size)

        # Both structures should be separated
        assert((acquisition[0].children.to_value_set & acquisition[1].children.to_value_set).empty?)
    end

    def test_child_name_direct_disambiguation
        device_tests_spec
        orocos_engine.add("ImageAcquisition").
            using("acquisition" => "leftCamera")
        orocos_engine.add("ImageAcquisition").
            using("acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(7, plan.size)

        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        acquisition = plan.find_tasks(ImageAcquisition).
            with_child(Camera::Driver).
            with_child(Camera::Filter).to_a
        assert_equal(2, acquisition.size)

        # Both structures should be separated
        assert((acquisition[0].children.to_value_set & acquisition[1].children.to_value_set).empty?)
    end

    def test_system_instanciation
        engine = RobyPlugin::Engine.new(plan, sys_model)
        simple_composition
        engine.add "simple"

        engine.resolve_compositions
    end
end

