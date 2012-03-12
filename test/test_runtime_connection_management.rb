BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_RuntimeConnectionManagement < Test::Unit::TestCase
    include RobyPluginCommonTest
    needs_no_orogen_projects

    attr_reader :connection_manager
    def setup
        super
        @connection_manager = Orocos::RobyPlugin::RuntimeConnectionManagement.new(plan)
    end

    def test_connection_application_on_configured_tasks
        klass = mock_task_context_model do
            output_port 'out', 'int'
            input_port 'in', 'int'
        end
        source, sink = prepare_plan :permanent => 2, :model => klass
        mock_configured_task(source)
        mock_configured_task(sink)
        source.orogen_task.should_receive(:running?).and_return(false)
        sink.orogen_task.should_receive(:running?).and_return(false)

        source.connect_ports sink, ['out', 'in'] => Hash.new
        source.orogen_task.port('out').should_receive(:connect_to).once.with(sink.orogen_task.port('in'), FlexMock.any).ordered
        connection_manager.update

        source.disconnect_ports sink, [['out', 'in']]
        source.orogen_task.port('out').should_receive(:disconnect_from).once.with(sink.orogen_task.port('in')).ordered.and_return(true)
        connection_manager.update
    end

    def test_connections_are_not_applied_on_unconfigured_tasks
        klass = mock_task_context_model do
            output_port 'out', 'int'
            input_port 'in', 'int'
        end
        source, sink = prepare_plan :permanent => 2, :model => klass
        source.on(:start) { puts "STARTING" }
        sink.on(:start) { puts "STARTING" }

        source.connect_ports sink, ['out', 'in'] => Hash.new
        source.orogen_task.port('out').should_receive(:connect_to).never
        connection_manager.update

        source.disconnect_ports sink, [['out', 'in']]
        source.orogen_task.port('out').should_receive(:disconnect_from).never
        connection_manager.update
    end
end


