require 'syskit'
require 'syskit/test'

class TC_TaskContext < Test::Unit::TestCase
    include Syskit::SelfTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_find_input_port
        task = stub_roby_task_context do
            input_port "in", "int"
            output_port "out", "int"
        end
        assert_equal task.orocos_task.port("in"), task.find_input_port("in")
        assert_equal nil, task.find_input_port("out")
        assert_equal nil, task.find_input_port("does_not_exist")
    end

    def test_find_output_port
        task = stub_roby_task_context do
            input_port "in", "int"
            output_port "out", "int"
        end
        assert_equal task.orocos_task.port("out"), task.find_output_port("out")
        assert_equal nil, task.find_output_port("does_not_exist")
        assert_equal nil, task.find_output_port("in")
    end

    def test_input_port_passes_if_find_input_port_returns_a_value
        task = flexmock(stub_roby_task_context)
        task.should_receive(:find_input_port).and_return(port = Object.new)
        assert_same port, task.input_port("port")
    end

    def test_input_port_raises_if_find_input_port_returns_nil
        task = flexmock(stub_roby_task_context)
        task.should_receive(:find_input_port).and_return(nil)
        assert_raises(Orocos::NotFound) { task.input_port("port") }
    end

    def test_output_port_passes_if_find_output_port_returns_a_value
        task = flexmock(stub_roby_task_context)
        task.should_receive(:find_output_port).and_return(port = Object.new)
        assert_same port, task.output_port("port")
    end

    def test_output_port_raises_if_find_output_port_returns_nil
        task = flexmock(stub_roby_task_context)
        task.should_receive(:find_output_port).and_return(nil)
        assert_raises(Orocos::NotFound) { task.output_port("port") }
    end

    def test_instanciate
        task_model = TaskContext.new_submodel
        task = task_model.instanciate(orocos_engine, nil, :task_arguments => {:conf => ['default']})
        assert_equal([[task_model], {:conf => ['default']}], task.fullfilled_model)
    end

end

