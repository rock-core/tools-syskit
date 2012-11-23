BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_InstanceSpec < Test::Unit::TestCase
    include RobyPluginCommonTest

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

        srv = @simple_service_model = DataModel.new_submodel do
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
    end

    def test_instance_spec_port
        spec = InstanceRequirements.new([simple_task_model])
        port = spec.out_port
        assert_equal ComponentModel::Port.new(spec, simple_task_model.find_output_port('out')), port
    end

    def test_instance_spec_service
        spec = InstanceRequirements.new([simple_task_model])
        srv = spec.simple_service_srv
        assert_equal srv.models, spec.models
        assert_equal simple_task_model.simple_service_srv, srv.service
    end

    def test_instance_spec_service_port
        spec = InstanceRequirements.new([simple_task_model])
        srv = spec.simple_service_srv
        port = srv.srv_out_port
        assert_equal ComponentModel::Port.new(srv, simple_task_model.find_output_port('out')), port
    end

    def test_instance_spec_child
        spec = simple_composition_model.use(simple_task_model)
        child = spec.srv_child
        assert_same spec, child.composition
    end

    def test_instance_spec_child_port
        spec = simple_composition_model.use(simple_task_model)
        child = spec.srv_child
        port = child.srv_out_port
        assert_equal ComponentModel::Port.new(child, simple_service_model.find_output_port('srv_out')), port
    end
end


