BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'
require 'roby/schedulers/basic'

class TC_RobyPlugin_Deployment < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
        super
        @orocos_update = engine.add_propagation_handler(&Orocos::RobyPlugin.method(:update))
    end

    needs_no_orogen_projects

    def test_deployment_nominal_actions
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Orocos::RobyPlugin::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        assert_any_event(task.stop_event) do
            task.stop!
        end
        assert task.finished?
        assert !task.failed?
        assert !task.orogen_deployment.alive?, "orogen_deployment.alive? returned true"
    end

    def test_deployment_crash_handling
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Orocos::RobyPlugin::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        Orocos.logger.level = Logger::FATAL
        assert_any_event(task.stop_event) do
            task.orogen_deployment.kill(false)
        end
    end

    def test_deployment_task
        Roby.app.load_orogen_project "echo"
        plan.add(deployment = Orocos::RobyPlugin::Deployments::Echo.new)
        task       = deployment.task 'echo_Echo'
        assert task.child_object?(deployment, TaskStructure::ExecutionAgent)
    end
end


