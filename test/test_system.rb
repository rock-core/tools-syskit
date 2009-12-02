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

    def test_device_selection
        device_tests_spec

        subsystem = sys_model.subsystem "ImageAcquisition" do
            add "camera"
            add "camera::Filter"
        end

        orocos_engine.add("ImageAcquisition", :as => 'leftImage').
            using("camera" => "leftCamera")
        orocos_engine.add("ImageAcquisition", :as => 'rightImage').
            using("camera" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(7, plan.size)

        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        left_camera = plan.find_tasks(camera_driver, :device_name => 'leftCamera').
            to_a.first
        assert(left_camera)
        right_camera = plan.find_tasks(camera_driver, :device_name => 'rightCamera').
            to_a.first
        assert(right_camera)
        assert_not_same(left_camera, right_camera)

        # Now, check the rest of the structure
        right_parents = right_camera.parents.to_a
        assert(1, right_parents.size)
        right_image = right_parents.first
        assert(right_image.root?)

        left_parents = left_camera.parents.to_a
        assert(1, left_parents.size)
        left_image = left_parents.first
        assert(left_image.root?)

        assert_not_same(left_image, right_image)
        assert(left_filter  = left_image.children.find { |t| t != left_camera })
        assert(right_filter = right_image.children.find { |t| t != right_camera })
        assert_not_same(left_filter, right_filter)
    end

    def test_system_instanciation
        engine = RobyPlugin::Engine.new(plan, sys_model)
        simple_composition
        engine.add "simple"

        engine.resolve_compositions
    end
end

