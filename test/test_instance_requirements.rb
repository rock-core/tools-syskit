require 'syskit'
require 'syskit/test'

class TC_InstanceRequirements < Test::Unit::TestCase
    include Syskit::SelfTest

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

        srv = @simple_service_model = DataService.new_submodel do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        @simple_component_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_component_model.provides simple_service_model, :as => 'simple_service',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_task_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_task_model.provides simple_service_model, :as => 'simple_service',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_composition_model = Composition.new_submodel do
            add srv, :as => 'srv'
            export self.srv.srv_in
            export self.srv.srv_out
            provides srv, :as => 'srv'
        end
    end

    def test_port
        spec = InstanceRequirements.new([simple_task_model])
        port = spec.out_port
        assert_equal Models::Component::Port.new(spec, simple_task_model.find_output_port('out')), port
    end

    def test_service
        spec = InstanceRequirements.new([simple_task_model])
        srv = spec.simple_service_srv
        assert_equal srv.models, spec.models
        assert_equal simple_task_model.simple_service_srv, srv.service
    end

    def test_service_port
        spec = InstanceRequirements.new([simple_task_model])
        srv = spec.simple_service_srv
        port = srv.srv_out_port
        assert_equal Models::Component::Port.new(srv, simple_task_model.find_output_port('out')), port
    end

    def test_child
        spec = simple_composition_model.use(simple_task_model)
        child = spec.srv_child
        assert_same spec, child.composition
    end

    def test_child_port
        spec = simple_composition_model.use(simple_task_model)
        child = spec.srv_child
        port = child.srv_out_port
        assert_equal Models::Component::Port.new(child, simple_service_model.find_output_port('srv_out')), port
    end

    def test_composition_use_validates_child_name_to_service_mapping
        raise NotImplementedError
    end
end

