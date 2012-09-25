BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_TaskContext < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_create
        model = TaskContext.create('my::task') do
            input_port "port", "int"
            property "property", "int"
        end
        assert(model < Orocos::RobyPlugin::TaskContext)
        assert_equal("My::Task", model.name)
        assert_equal("my::task", model.interface.name)
        assert(model.interface.find_input_port("port"))
        assert(model.interface.find_property("property"))
    end

    def test_driver_for
        model = TaskContext.create('my::task') do
            input_port "port", "int"
            property "property", "int"
        end
        model.instance_variable_set :@system_model, sys_model
        model.driver_for "Camera"

        assert_kind_of Orocos::RobyPlugin::DeviceModel, Orocos::RobyPlugin::Dev::Camera
        assert model.fullfills?(Orocos::RobyPlugin::Dev::Camera)
    end
end


