BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_Proxies < Test::Unit::TestCase
    include RobyPluginCommonTest

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
        assert !task.failed?
        assert !task.orogen_deployment.alive?
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
            task.orogen_deployment.kill(false, 'ABRT')
        end
    end

    def test_deployment_task
        Roby.app.load_orogen_project "echo"
        deployment = Orocos::RobyPlugin::Deployments::Echo.new
        task       = deployment.task 'echo_Echo'
        assert task.child_object?(deployment, TaskStructure::ExecutionAgent)
        plan.add(task)
    end

    def test_task_executable_flag
        Roby.app.load_orogen_project "states"

        engine.run

        ::Robot.logger.level = Logger::WARN
        deployment = Orocos::RobyPlugin::Deployments::States.new
        task       = deployment.task 'states_Task'

        assert !task.executable?
        task_exec_flag1, task_exec_flag2, task_exec_flag3 = nil

        deployment.on :start do |event|
            task_exec_flag1 = task.executable?
        end
        deployment.on :ready do |event|
            task_exec_flag2 = task.executable?
        end
        task.singleton_class.class_eval do
            define_method :configure do
                task_exec_flag3 = executable?
            end
        end

        assert_any_event(deployment.ready_event) do
            plan.add_permanent(task)
            deployment.start!
	end

        assert !task_exec_flag1
        assert !task_exec_flag2
        assert !task_exec_flag3
    end

    def test_task_model_definition
        Roby.app.load_orogen_project "echo"

        assert_equal Roby.app.orocos_system_model, Echo::Echo.system
        assert_kind_of(Orocos::RobyPlugin::Project, Orocos::RobyPlugin::Echo)
        # Should have a task context model
        assert(Orocos::RobyPlugin::Echo::Echo < Orocos::RobyPlugin::TaskContext)
        # And a deployment model
        assert(Orocos::RobyPlugin::Deployments::Echo < Orocos::RobyPlugin::Deployment)
        # The orogen_spec should be a task context model
        assert_kind_of(Orocos::Generation::TaskContext, Orocos::RobyPlugin::Echo::Echo.orogen_spec)
    end

    def test_task_port_access
        Roby.app.load_orogen_project "echo"

        assert(input  = Echo::Echo.port('input'))
        assert_same(input, Echo::Echo.input)
        assert_equal('input', input.name)
        assert(output = Echo::Echo.port('output'))
        assert_same(output, Echo::Echo.output)
        assert_equal('output', output.name)

        assert_equal(['input', 'input_struct'].to_set, Echo::Echo.each_input.map(&:name).to_set)
        assert_equal(['output', 'state'].to_set, Echo::Echo.each_output.map(&:name).to_set)
    end

    def test_task_model_inheritance
        Roby.app.load_orogen_project "echo"

        assert(root_model = Roby.app.orocos_tasks['RTT::TaskContext'])
        assert_same root_model, Orocos::RobyPlugin::TaskContext
        assert(echo_model = Roby.app.orocos_tasks['echo::Echo'])
        assert(echo_model < root_model)
        assert(echo_submodel = Roby.app.orocos_tasks['echo::EchoSubmodel'])
        assert(echo_submodel < echo_model)
    end

    def test_task_nominal
        Roby.app.load_orogen_project "echo"
	engine.run

        deployment = Orocos::RobyPlugin::Deployments::Echo.new
        task       = deployment.task 'echo_Echo'
        assert_any_event(task.start_event) do
            plan.add_permanent(task)
            task.start!
	end

        assert_any_event(task.stop_event) do
            task.stop!
        end
    end

    def test_task_extended_states_definition
        Roby.app.load_orogen_project "states"
        deployment = Orocos::RobyPlugin::Deployments::States.new
        plan.add(task = deployment.task('states_Task'))

        assert task.has_event?(:custom_runtime)
        assert !task.event(:custom_runtime).terminal?
        assert task.has_event?(:custom_fatal)
        assert task.event(:custom_fatal).terminal?
        assert task.has_event?(:custom_error)
        assert task.event(:custom_error).terminal?
    end

    def test_task_runtime_error
        Roby.app.load_orogen_project "states"
	engine.run

        means_of_termination = [
            [:stop            ,  :success],
            [:do_runtime_error,  :runtime_error],
            [:do_custom_error ,  :custom_error],
            [:do_fatal_error  ,  :fatal_error],
            [:do_custom_fatal ,  :custom_fatal] ]

        deployment = Orocos::RobyPlugin::Deployments::States.new
        plan.add_permanent(deployment)

        ::Robot.logger.level = Logger::WARN
        means_of_termination.each do |method, state|
            task = deployment.task 'states_Task'
            assert_any_event(task.start_event) do
                plan.add_permanent(task)
                task.start!
            end

            assert_any_event(task.event(state)) do
                task.orogen_task.send(method)
            end
        end
    end

    def test_task_fatal_error
        Roby.app.load_orogen_project "states"
	engine.run

        ::Robot.logger.level = Logger::WARN

        deployment = Orocos::RobyPlugin::Deployments::States.new
        task       = deployment.task 'states_Task'
        assert_any_event(task.start_event) do
            plan.add_permanent(task)
            task.start!
	end

        assert_any_event(task.fatal_error_event) do
            task.orogen_task.do_fatal_error
        end
        assert(task.failed?)
    end

    def test_connects_after_configuration_before_startup
        Roby.app.load_orogen_project "system_test"

        plan.add(deployment = Orocos::RobyPlugin::Deployments::System.new)
        system_test = Orocos::RobyPlugin::SystemTest
        plan.add_permanent(control = deployment.task('control'))
        plan.add_permanent(motors  = deployment.task('motor_controller'))
        control.add_sink(motors, { ['cmd_out', 'command'] => Hash.new })

        was_executable, was_connected = nil
        motors.singleton_class.class_eval do
            define_method :configure do
                was_executable = executable?
                was_connected  = Roby.app.orocos_engine.registered_connection?(control, 'cmd_out', motors, 'command')
            end
        end

	engine.run
        assert_event_emission(control.start_event & motors.start_event) do
            control.signals :start, motors, :start
            control.start!
        end
        assert_event_emission(motors.start_event) { motors.start! }
        assert(!was_executable)
        assert(!was_connected)
        assert(control.orogen_task.port('cmd_out').connected?)
        assert(motors.orogen_task.port('command').connected?)
    end

    def test_connection_change
        Roby.app.load_orogen_project "system_test"
        Orocos::RobyPlugin::Engine.logger.level = Logger::INFO

        plan.add_permanent(deployment = Orocos::RobyPlugin::Deployments::System.new)
        system_test = Orocos::RobyPlugin::SystemTest
        plan.add_permanent(control = deployment.task('control'))
        plan.add_permanent(motors  = deployment.task('motor_controller'))
        control.add_sink(motors, { ['cmd_out', 'command'] => Hash.new })

        engine.run

        assert_event_emission(control.start_event) { control.start! }
        assert_event_emission(motors.start_event)  { motors.start! }

        assert(control.orogen_task.port('cmd_out').connected?)
        assert(motors.orogen_task.port('command').connected?)
        plan.execute do
            control.remove_sink(motors)
        end
        engine.wait_one_cycle
        assert(!motors.orogen_task.port('command').connected?)
        assert(!control.orogen_task.port('cmd_out').connected?)
    end

    def test_dynamic_ports
        Roby.app.load_orogen_project 'system_test'

        assert(SystemTest::CanBus.dynamic_output_port?('motors'))
        assert(!SystemTest::CanBus.dynamic_input_port?('motors'))
        assert(SystemTest::CanBus.dynamic_input_port?('motorsw'))
    end

    def test_update_connection_policy
        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => true }
        assert_equal(Orocos::Port.validate_policy(old_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => true, :pull => true }
        assert_equal(nil, Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => false }
        assert_equal(nil, Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :data }
        new_policy = { :type => :data, :init => false }
        assert_equal(Orocos::Port.validate_policy(old_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :buffer, :size => 2 }
        new_policy = { :type => :buffer, :size => 1 }
        assert_equal(Orocos::Port.validate_policy(old_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :buffer, :size => 1 }
        new_policy = { :type => :buffer, :size => 2 }
        assert_equal(Orocos::Port.validate_policy(new_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))
    end
end

