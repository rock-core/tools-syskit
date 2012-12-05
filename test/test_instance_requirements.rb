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
            export srv_child.srv_in_port
            export srv_child.srv_out_port
            provides srv, :as => 'srv'
        end
    end

    def test_port
        spec = InstanceRequirements.new([simple_task_model])
        port = spec.out_port

        assert_equal Models::OutputPort.new(spec, simple_task_model.find_output_port('out').orogen_model), port
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
        assert_equal Models::OutputPort.new(srv, simple_task_model.find_output_port('out').orogen_model, 'srv_out'), port
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
        assert_equal Models::OutputPort.new(child, simple_service_model.find_output_port('srv_out').orogen_model), port
    end

    def test_find_data_service_from_type_with_matching_service
        s = DataService.new_submodel
        subs = s.new_submodel
        req = InstanceRequirements.new([subs])
        assert_same req, req.find_data_service_from_type(s)
    end

    def test_find_data_service_from_type_with_matching_component
        s = DataService.new_submodel
        c = Component.new_submodel { provides s, :as => 's' }
        subc = c.new_submodel
        req = InstanceRequirements.new([subc])

        expected = req.dup
        expected.select_service(subc.s_srv)
        assert_equal expected, req.find_data_service_from_type(s)
    end

    def test_find_data_service_from_type_ambiguous
        s = DataService.new_submodel
        c = Component.new_submodel do
            provides s, :as => 'srv'
            provides s, :as => 'srv1'
        end
        req = InstanceRequirements.new([c])

        assert_raises(AmbiguousServiceSelection) { req.find_data_service_from_type(s) }
    end

    def test_find_data_service_from_type_no_match
        s = DataService.new_submodel
        c = Component.new_submodel
        key = DataService.new_submodel
        req = InstanceRequirements.new([key])

        assert !req.find_data_service_from_type(s)
    end

    def test_composition_use_validates_child_name_to_service_mapping
        raise NotImplementedError
    end
end

