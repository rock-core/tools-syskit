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

    def test_find_input_port
        task = mock_roby_task_context do
            input_port "in", "int"
            output_port "out", "int"
        end
        mock_configured_task(task)
        task.orogen_task.should_receive(:port).with("does_not_exist").once
        assert_equal task.orogen_task.port("in"), task.find_input_port("in")
        assert_equal nil, task.find_input_port("does_not_exist")
        assert_equal nil, task.find_input_port("out")
    end

    def test_find_output_port
        task = mock_roby_task_context do
            input_port "in", "int"
            output_port "out", "int"
        end
        mock_configured_task(task)
        task.orogen_task.should_receive(:port).with("does_not_exist").once
        assert_equal task.orogen_task.port("out"), task.find_output_port("out")
        assert_equal nil, task.find_output_port("does_not_exist")
        assert_equal nil, task.find_output_port("in")
    end

    def test_input_port_passes_if_find_input_port_returns_a_value
        task = mock_roby_task_context
        task.should_receive(:find_input_port).and_return(port = Object.new)
        assert_same port, task.input_port("port")
    end

    def test_input_port_raises_if_find_input_port_returns_nil
        task = mock_roby_task_context
        task.should_receive(:find_input_port).and_return(nil)
        assert_raises(ArgumentError) { task.input_port("port") }
    end

    def test_output_port_passes_if_find_output_port_returns_a_value
        task = mock_roby_task_context
        task.should_receive(:find_output_port).and_return(port = Object.new)
        assert_same port, task.output_port("port")
    end

    def test_output_port_raises_if_find_output_port_returns_nil
        task = mock_roby_task_context
        task.should_receive(:find_output_port).and_return(nil)
        assert_raises(ArgumentError) { task.output_port("port") }
    end
end

