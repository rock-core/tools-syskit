BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'
require 'roby/schedulers/basic'

class TC_RobyPlugin_Task < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def test_task_executable_flag
        Roby.app.load_orogen_project "states"

        engine.run

        ::Robot.logger.level = Logger::WARN
        plan.add(deployment = Orocos::RobyPlugin::Deployments::States.new)
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

        assert_equal Roby.app.orocos_system_model, Echo::Echo.system_model
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

        assert(input  = Echo::Echo.find_input_port('input'))
        assert_same(input, Echo::Echo.input)
        assert_equal('input', input.name)
        assert(output = Echo::Echo.find_output_port('output'))
        assert_same(output, Echo::Echo.output)
        assert_equal('output', output.name)

        assert_equal(['input', 'input_struct', 'input_opaque'].to_set, Echo::Echo.each_input_port.map(&:name).to_set)
        assert_equal(['output', 'output_opaque', 'state', 'ondemand'].to_set, Echo::Echo.each_output_port.map(&:name).to_set)
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
        Roby.logger.level = Logger::DEBUG
        Roby.app.load_orogen_project "echo"
	engine.run
        task, _ = start_task_context Orocos::RobyPlugin::Deployments::Echo, "echo_Echo"

        assert_any_event(task.stop_event) do
            task.stop!
        end
    end

    def test_deployment_start_stop_immediately
        Roby.app.load_orogen_project "states"
        engine.run
        deployment = nil
        assert_event_emission do
            plan.add_permanent(deployment = Orocos::RobyPlugin::Deployments::States.new)
            deployment.on :start do |ev|
                deployment.stop!
            end
            deployment.stop_event
        end
    end

    def common_extended_states_definition_test(task_name)
        Roby.app.load_orogen_project "states"
        plan.add(deployment = Orocos::RobyPlugin::Deployments::States.new)
        task = deployment.task(task_name)

        assert task.has_event?(:custom_runtime)
        assert !task.event(:custom_runtime).terminal?
        assert_same :custom_runtime, task.state_event(:CUSTOM_RUNTIME)

        assert task.has_event?(:custom_exception)
        assert task.event(:custom_exception).terminal?
        assert_same :custom_exception, task.state_event(:CUSTOM_EXCEPTION)

        assert task.has_event?(:custom_fatal)
        assert task.event(:custom_fatal).terminal?
        assert_same :custom_fatal, task.state_event(:CUSTOM_FATAL)

        assert task.has_event?(:custom_error)
        assert !task.event(:custom_error).terminal?
        assert_same :custom_error, task.state_event(:CUSTOM_ERROR)

        task
    end

    def test_task_extended_states_definition
        task = common_extended_states_definition_test('states_Task')

        assert !task.has_event?(:subclass_custom_runtime)
        assert_same nil, task.state_event(:SUBCLASS_CUSTOM_RUNTIME)
        assert !task.has_event?(:subclass_custom_exception)
        assert_same nil, task.state_event(:SUBCLASS_CUSTOM_EXCEPTION)
        assert !task.has_event?(:subclass_custom_fatal)
        assert_same nil, task.state_event(:SUBCLASS_CUSTOM_FATAL)
        assert !task.has_event?(:subclass_custom_error)
        assert_same nil, task.state_event(:SUBCLASS_CUSTOM_ERROR)
    end

    def test_task_extended_states_definition_in_subtask
        task = common_extended_states_definition_test('states_Subtask')

        assert task.has_event?(:subclass_custom_runtime)
        assert !task.event(:subclass_custom_runtime).terminal?
        assert_same :subclass_custom_runtime, task.state_event(:SUBCLASS_CUSTOM_RUNTIME)

        assert task.has_event?(:subclass_custom_exception)
        assert task.event(:subclass_custom_exception).terminal?
        assert_same :subclass_custom_exception, task.state_event(:SUBCLASS_CUSTOM_EXCEPTION)

        assert task.has_event?(:subclass_custom_fatal)
        assert task.event(:subclass_custom_fatal).terminal?
        assert_same :subclass_custom_fatal, task.state_event(:SUBCLASS_CUSTOM_FATAL)

        assert task.has_event?(:subclass_custom_error)
        assert !task.event(:subclass_custom_error).terminal?
        assert_same :subclass_custom_error, task.state_event(:SUBCLASS_CUSTOM_ERROR)
    end

    def start_task_context(deployment, task_name)
        deployment_task = nil
        task = nil
        engine.execute do
            plan.add_mission(deployment_task = deployment.new)
            plan.add_mission(task = deployment_task.task(task_name))
        end
        assert_event_emission deployment_task.ready_event
        assert_event_emission task.start_event
        return task, deployment_task
    end

    def test_task_runtime_error
        Roby.app.load_orogen_project "states"

        runtime_errors = [
            [:do_runtime_error,  :runtime_error],
            [:do_custom_error ,  :custom_error]]

        ::Robot.logger.level = Logger::WARN
	engine.run

        task, _ = start_task_context Orocos::RobyPlugin::Deployments::States, 'states_Task'
        runtime_errors.each do |method, state|
            assert_any_event(task.event(state)) do
                task.orogen_task.send(method)
            end
            assert_any_event(task.event(:running)) do
                task.orogen_task.do_recover
            end
        end
    end

    def test_task_runtime_error_in_subtask
        Roby.app.load_orogen_project "states"

        runtime_errors = [
            [:do_runtime_error,  :runtime_error],
            [:do_custom_error ,  :custom_error]]

        ::Robot.logger.level = Logger::WARN
	engine.run

        task, _ = start_task_context Orocos::RobyPlugin::Deployments::States, 'states_Subtask'
        runtime_errors.each do |method, state|
            assert_any_event(task.event(state)) do
                task.orogen_task.send(method)
            end
            assert_any_event(task.event(:running)) do
                task.orogen_task.do_recover
            end
        end
    end

    def test_task_fatal_error_handling(operation = :do_fatal_error, fatal_event = :fatal_error)
        Roby.app.load_orogen_project "states"

        ::Robot.logger.level = Logger::WARN
	engine.run

        task, deployment = start_task_context Orocos::RobyPlugin::Deployments::States, 'states_Task'
        assert_any_event(task.stop_event) do
            task.orogen_task.send(operation)
        end
        engine.execute do
            assert(task.fatal_error_event.happened?)
            assert(task.event(fatal_event).happened?)
        end
        engine.execute do
            plan.add_permanent(task = deployment.task('states_Task'))
        end
        sleep 0.1
        engine.execute do
            assert !task.executable?
        end
    end

    def test_task_custom_fatal_error_handling
        test_task_fatal_error_handling(:do_custom_fatal, :custom_fatal)
    end

    def test_task_termination
        Roby.app.load_orogen_project "states"

        means_of_termination = [
            [:stop            ,  :success],
            [:do_exception  ,  :exception],
            [:do_custom_exception ,  :custom_exception] ]

        ::Robot.logger.level = Logger::WARN
	engine.run

        means_of_termination.each do |method, state|
            task, _ = start_task_context Orocos::RobyPlugin::Deployments::States, 'states_Task'
            assert_event_emission(task.event(state)) do
                task.orogen_task.send(method)
            end
            engine.execute do
                if state == :success
                    assert(task.success?)
                else
                    assert(task.failed?)
                end
            end
        end
    end

    def test_connects_after_configuration_before_startup
        Roby.app.filter_backtraces = false
        Roby.app.load_orogen_project "system_test"

        configure_called = false
        was_executable, was_connected = true

        Orocos::RobyPlugin::Engine.logger.level = Logger::INFO

        control, motors = nil
        engine.run
        assert_event_emission do
            plan.add(deployment = Orocos::RobyPlugin::Deployments::System.new)
            plan.add_mission(control = deployment.task('control'))
            plan.add_mission(motors  = deployment.task('motor_controller'))
            plan.add_permanent(started_ev = (motors.start_event & control.start_event))
            control.add_sink(motors, { ['cmd_out', 'command'] => Hash.new })
            motors.singleton_class.class_eval do
                define_method :configure do
                    super()
                    configure_called = true
                    was_executable = executable?
                    was_connected  = Orocos::RobyPlugin::ActualDataFlow.linked?(control.orogen_task, motors.orogen_task)
                end
            end
            started_ev
        end

        assert(configure_called, "the task's #configure method has not been called")
        assert(!was_executable, "the task was executable in #configure")
        assert(!was_connected, "the task was already connected in #configure")
        assert(control.orogen_task.port('cmd_out').connected?, 'control output port is not connected')
        assert(motors.orogen_task.port('command').connected?,
            "motors input port is not connected, executable? returns #{motors.executable?} and all_inputs_connected? #{motors.all_inputs_connected?}")
    end

    def test_connection_change
        Roby.app.load_orogen_project "system_test"

        plan.add_permanent(deployment = Orocos::RobyPlugin::Deployments::System.new)
        system_test = Orocos::RobyPlugin::SystemTest
        plan.add_permanent(control = deployment.task('control'))
        control.conf = ['default']
        plan.add_permanent(motors  = deployment.task('motor_controller'))
        motors.conf = ['default']
        control.connect_ports(motors, { ['cmd_out', 'command'] => Hash.new })

        engine.run

        assert_event_emission(control.start_event)
        assert_event_emission(motors.start_event)

        assert(control.orogen_task.port('cmd_out').connected?)
        assert(motors.orogen_task.port('command').connected?)
        plan.execute do
            control.disconnect_ports(motors, [['cmd_out', 'command']])
        end
        engine.wait_one_cycle
        assert(!motors.orogen_task.port('command').connected?)
        assert(!control.orogen_task.port('cmd_out').connected?)
    end

    def test_dynamic_ports
        Roby.app.load_orogen_project 'system_test'

        assert(SystemTest::CanBus.has_dynamic_output_port?('motors'))
        assert(!SystemTest::CanBus.has_dynamic_input_port?('motors'))
        assert(SystemTest::CanBus.has_dynamic_input_port?('wmotors'))
    end

    def test_update_connection_policy
        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => true }
        assert_equal(Orocos::Port.validate_policy(old_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => true, :pull => true }
        assert_equal(Orocos::Port.validate_policy(new_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :data, :init => true }
        new_policy = { :type => :data, :init => false }
        assert_raises(ArgumentError) { Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy) }

        old_policy = { :type => :data }
        new_policy = { :type => :data, :init => false }
        assert_equal(Orocos::Port.validate_policy(new_policy), Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy))

        old_policy = { :type => :buffer, :size => 2 }
        new_policy = { :type => :buffer, :size => 1 }
        assert_raises(ArgumentError) { Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy) }

        old_policy = { :type => :buffer, :size => 1 }
        new_policy = { :type => :buffer, :size => 2 }
        assert_raises(ArgumentError) { Orocos::RobyPlugin.update_connection_policy(old_policy, new_policy) }
    end
end

