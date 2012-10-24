BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_Engine < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_instanciate_toplevel_task
        task_model = mock_roby_task_context_model "my::task"
        deployment = mock_roby_deployment_model(task_model)
        task = task_model.instanciate(orocos_engine, nil, :task_arguments => {:conf => ['default']})
        assert_equal([[task_model], {:conf => ['default']}], task.fullfilled_model)
    end

    def test_reconfigure_child_task
        task_model = mock_roby_task_context_model "my::task"
        composition_model = mock_roby_composition_model do
            add task_model, :as => 'child'
        end
        deployment = mock_roby_deployment_model(task_model)

        orocos_engine.add_mission(composition_model)
        orocos_engine.resolve

        original = plan.find_tasks(Component).to_a
        assert_equal(2, original.size)

        orocos_engine.add_mission(task_model).
            with_conf('non_default')
        orocos_engine.resolve

        tasks = plan.find_tasks(Component).to_a
        assert_equal(4, tasks.size)
        assert_equal(original, plan.static_garbage_collect.to_a)
        assert_equal(['non_default'],
                     plan.missions.first.child_child.conf)
    end
    def test_reconfigure_toplevel_task
        task_model = mock_roby_task_context_model "my::task"
        deployment = mock_roby_deployment_model(task_model)

        orocos_engine.add_mission(task_model)
        orocos_engine.resolve
        original_task = plan.find_tasks(task_model).to_a
        assert_equal(1, original_task.size)
        original_task = original_task.first

        orocos_engine.add_mission(task_model).
            with_conf('non_default')
        orocos_engine.resolve

        tasks = plan.find_tasks(task_model).to_a
        assert_equal(2, tasks.size)
        tasks.delete(original_task)
        new_task = tasks.first

        assert_equal([original_task], plan.static_garbage_collect.to_a)
    end

    def test_add_permanent_task
        plan.engine.scheduler = nil
        task_model = mock_roby_task_context_model "my::task"
        deployment = mock_roby_deployment_model(task_model)
        task = task_model.as_plan
        plan.add_permanent(task)
        srv = task.as_service
        task.planning_task.start!
        orocos_engine.resolve
        assert plan.permanent?(srv.task)
        orocos_engine.resolve
        assert plan.permanent?(srv.task)
    end

    def test_add_mission_task
        plan.engine.scheduler = nil
        task_model = mock_roby_task_context_model "my::task"
        deployment = mock_roby_deployment_model(task_model)
        task = task_model.as_plan
        plan.add_mission(task)
        srv = task.as_service
        task.planning_task.start!
        orocos_engine.resolve
        assert plan.mission?(srv.task)
        orocos_engine.resolve
        assert plan.mission?(srv.task)
    end
end


