BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_Roby_Test < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_mock_roby_task_context_model
        mock = mock_roby_task_context_model("ComponentName") do
            input_port "in", "/int"
            output_port "out", "/int"
        end
        assert_equal "ComponentName", mock.name
        assert mock.respond_to?(:should_receive)
        assert mock.find_input_port("in")
        assert mock.find_output_port("out")

        # Created instances should also be mocked
        mock = mock.new
        assert mock.respond_to?(:should_receive)
        assert_equal mock.class.orogen_spec, mock.orogen_task.model
        assert mock.find_input_port("in")
        assert mock.find_output_port("out")
    end
end

