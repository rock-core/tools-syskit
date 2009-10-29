BASE_DIR = File.expand_path( '..', File.dirname(__FILE__))
$LOAD_PATH.unshift BASE_DIR
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'app'
require 'roby-orocos'

APP_DIR = File.join(BASE_DIR, "test")

class TC_Orocos < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, '..', 'test', 'working_copy')
    def setup
        super

        Roby.app.extend Roby::Orocos::Application
        save_collection Roby.app.loaded_orogen_projects
        save_collection Roby.app.orocos_tasks
        save_collection Roby.app.orocos_deployments

        @update_handler = engine.each_cycle(&Roby::Orocos.method(:update))

        FileUtils.mkdir_p Roby.app.log_dir
        @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
        ENV['PKG_CONFIG_PATH'] += ":#{File.join(WORK_DIR, "prefix", 'lib', 'pkgconfig')}"
    end
    def teardown
        Roby.app.orocos_clear_models
        ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
        ::Orocos::CORBA.instance_variable_set :@loaded_toolkits, []
        ENV['PKG_CONFIG_PATH'] = @old_pkg_config

        FileUtils.rm_rf Roby.app.log_dir

        super
    end

    def test_constant_definitions
        Roby.app.load_orogen_project "echo"

        assert_kind_of(Roby::Orocos::Project, Roby::Orocos::Echo)
        # Should have a task context model
        assert(Roby::Orocos::Echo::Echo < Roby::Orocos::TaskContext)
        # And a deployment model
        assert(Roby::Orocos::Deployments::Echo < Roby::Orocos::Deployment)
    end

    def test_deployment_nominal_actions
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Roby::Orocos::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        assert_any_event(task.stop_event) do
            task.stop!
        end
    end

    def test_deployment_crash_handling
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Roby::Orocos::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        assert_any_event(task.failed_event) do
            task.orogen_deployment.kill
        end
    end

    def test_task_nominal
        Roby.app.load_orogen_project "echo"
	engine.run

        deployment = Roby::Orocos::Deployments::Echo.new
        task       = deployment.task 'Echo'
        assert_any_event(task.start_event) do
            plan.add_permanent(task)
            task.start!
	end

    end

end

