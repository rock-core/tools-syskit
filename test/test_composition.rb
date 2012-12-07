require 'syskit'
require 'syskit/test'

class TC_Composition < Test::Unit::TestCase
    include Syskit::SelfTest

    attr_reader :simple_component_model
    attr_reader :simple_task_model
    attr_reader :simple_service_model
    attr_reader :simple_composition_model

    def simple_models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def setup
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
            export self.srv_child.srv_in_port
            export self.srv_child.srv_out_port
            provides srv, :as => 'srv'
        end
    end

    def setup_with_port_mapping
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def test_explicit_connection
        component = simple_composition_model
        composition = Composition.new_submodel
        composition.add simple_component_model, :as => 'source'
        composition.add simple_component_model, :as => 'sink'
        composition.connect composition.source => composition.sink
        assert_equal({['source', 'sink'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
    end

    def test_explicit_connection_applies_port_mappings
        service, component, base = setup_with_port_mapping
        service1 = DataService.new_submodel do
            input_port 'specialized_in', '/int'
            output_port 'specialized_out', '/int'
            provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
        end
        component.provides service1, :as => 'specialized_service'

        composition = Class.new(base)
        composition.overload('srv', service1)

        base.add(service, :as => 'srv_in')
        base.connect(base.srv_child => base.srv_in_port)

        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'srv_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        composition.overload('srv_in', service1)
        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'specialized_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)

        composition = Class.new(composition)
        composition.overload('srv', component)
        assert_equal({['srv', 'srv_in'] => {['out', 'specialized_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        composition.overload('srv_in', component)
        assert_equal({['srv', 'srv_in'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
    end

    def assert_single_export(expected_name, expected_port, exports)
        exports = exports.to_a
        assert_equal(1, exports.size)
        export_name, exported_port = *exports.first
        assert_equal expected_name, export_name
        assert_equal expected_name, exported_port.name
        assert(exported_port.same_port?(expected_port))
    end

    def test_state_using_child_component
        cmp_model = Composition.new_submodel
        cmp_model.add simple_task_model, :as => 'child'
        cmp_model.state.pose = cmp_model.child.out_port

        source = cmp_model.state.pose.data_source
        assert_equal source, cmp_model.child.out_port
        assert_equal source.type, cmp_model.state.pose.type

        cmp = instanciate_component(cmp_model)
        flexmock(cmp).should_receive(:execute).and_yield
        flexmock(cmp).should_receive(:data_reader).with('child', 'out').once.and_return(reader = flexmock)
        cmp.resolve_state_sources
        assert_equal reader, cmp.state.data_sources.pose.reader
    end

    def test_state_using_child_service
        cmp_model = Composition.new_submodel
        cmp_model.add simple_service_model, :as => 'child'
        cmp_model.state.pose = cmp_model.child.srv_out_port

        source = cmp_model.state.pose.data_source
        assert_equal source, cmp_model.child.srv_out_port
        assert_equal source.type, cmp_model.state.pose.type

        cmp = instanciate_component(cmp_model.use('child' => simple_task_model))
        flexmock(cmp).should_receive(:execute).and_yield
        flexmock(cmp).should_receive(:data_reader).with('child', 'srv_out').once.and_return(reader = flexmock)
        cmp.resolve_state_sources
        assert_equal reader, cmp.state.data_sources.pose.reader
    end
end

