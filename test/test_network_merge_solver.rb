BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_NetworkMergeSolver < Test::Unit::TestCase
    include RobyPluginCommonTest

    attr_reader :solver
    attr_reader :simple_component_model
    attr_reader :simple_task_model
    attr_reader :simple_service_model
    attr_reader :simple_composition_model

    def simple_models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
        Roby.app.filter_backtraces = false
	super

        srv = @simple_service_model = sys_model.data_service_type("SimpleService") do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        @simple_component_model = mock_roby_component_model("SimpleComponent") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_component_model.provides simple_service_model,
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_task_model = mock_roby_task_context_model("SimpleTask") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_task_model.provides simple_service_model,
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_composition_model = mock_roby_composition_model("SimpleComposition") do
            add srv, :as => 'srv'
            export self.srv.srv_in
            export self.srv.srv_out
            provides srv
        end

        @solver = NetworkMergeSolver.new(plan)
    end

    def test_can_merge_empty_compositions
        plan.add(c0 = simple_composition_model.new)
        plan.add(c1 = simple_composition_model.new)
        assert solver.can_merge?(c0, c1, [])
    end

    def test_can_merge_composition_with_same_children
        plan.add(t = simple_component_model.new)
        plan.add(c0 = simple_composition_model.new)
        c0.depends_on(t)
        plan.add(c1 = simple_composition_model.new)
        c1.depends_on(t)
        assert solver.can_merge?(c0, c1, [])
    end

    def test_cannot_merge_composition_with_different_children
        plan.add(t = simple_component_model.new)
        plan.add(c0 = simple_composition_model.new)
        c0.depends_on(t)
        plan.add(c1 = simple_composition_model.new)
        assert !solver.can_merge?(c0, c1, [])
    end

    def test_cannot_merge_composition_with_same_children_in_different_roles
        plan.add(t = simple_component_model.new)
        plan.add(c0 = simple_composition_model.new)
        c0.depends_on(t, :role => 'child0')
        plan.add(c1 = simple_composition_model.new)
        c1.depends_on(t, :role => 'child1')
        assert !solver.can_merge?(c0, c1, [])
    end
end

