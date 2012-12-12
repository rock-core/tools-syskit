require 'syskit'
require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Models::Component do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    describe "#as_plan" do
        it "creates a plan pattern by calling InstanceRequirementsTask.suplan" do
            c = Syskit::Component.new_submodel
            flexmock(Syskit::InstanceRequirementsTask).should_receive(:subplan).with(c).and_return(obj = Object.new)
            assert_same obj, c.as_plan
        end
    end

    describe "#each_master_driver_service" do
        it "should list all master devices" do
            task_model = Syskit::TaskContext.new_submodel
            device = Syskit::Device.new_submodel
            task_model.provides device, :as => 'master1'
            task_model.provides device, :as => 'master2'
            task_model.provides device, :as => 'slave', :slave_of => 'master1'

            assert_equal [task_model.master1_srv, task_model.master2_srv].to_set,
                task_model.each_master_driver_service.to_set
        end
        it "should ignore pure data services" do
            task_model = Syskit::TaskContext.new_submodel
            device = Syskit::Device.new_submodel
            srv = Syskit::DataService.new_submodel
            task_model.provides device, :as => 'master1'
            task_model.provides srv, :as => 'srv'

            assert_equal [task_model.master1_srv], task_model.each_master_driver_service.to_a
        end
    end

    describe "#compute_port_mappings" do
        attr_reader :task_m, :srv_m
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port 'out', 'double'
                output_port 'other_out', 'double'
                output_port 'out_int', 'int'
                input_port 'in', 'int'
                input_port 'other_in', 'int'
                input_port 'in_double', 'double'
            end
            @srv_m = Syskit::DataService.new_submodel do
                output_port 'out', 'double'
                input_port 'in', 'int'
            end
        end

        it "maps service ports to task ports with same name and type" do
            mappings = task_m.compute_port_mappings(srv_m)
            assert_equal Hash['out' => 'out', 'in' => 'in'], mappings
        end
        it "maps service ports to task ports with using the port mappings" do
            mappings = task_m.compute_port_mappings(srv_m, 'out' => 'other_out', 'in' => 'other_in')
            assert_equal Hash['out' => 'other_out', 'in' => 'other_in'], mappings
        end
        it "raises if a port mapping leads to a port with the wrong direction" do
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, 'out' => 'in_double', 'in' => 'out_int') }
        end
        it "raises if a port mapping leads to a port with the wrong type" do
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, 'out' => 'out_int', 'in' => 'in_double') }
        end
        it "can pick a port by type if it is not ambiguous" do
            srv_m = Syskit::DataService.new_submodel do
                output_port 'out', 'int'
                input_port 'in', 'double'
            end
            assert_equal Hash['out' => 'out_int', 'in' => 'in_double'],
                task_m.compute_port_mappings(srv_m)
        end
        it "raises if asked to select a component port for an ambiguous type" do
            srv_m = Syskit::DataService.new_submodel do
                output_port 'bla', 'double'
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m) }
        end
    end

    describe "the dynamic service support" do
        attr_reader :task_m, :srv_m
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "int"
                dynamic_output_port /\w+_out/, "bool"
                dynamic_input_port /\w+_in/, "double"
            end
            @srv_m = Syskit::DataService.new_submodel do
                output_port "out", "bool"
                input_port "in", "double"
            end
        end

        describe "#find_dynamic_service" do
            it "should return a dynamic service bound to the current component model" do
                srv_m = self.srv_m
                dyn = task_m.dynamic_service srv_m, :as => "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                subtask_m = task_m.new_submodel
                assert_equal subtask_m, subtask_m.find_dynamic_service('dyn').component_model
            end
        end

        describe "#dynamic_service" do
            it "should create a DynamicService instance" do
                srv_m = self.srv_m
                result = task_m.dynamic_service srv_m, :as => "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                assert_kind_of Syskit::Models::Component::DynamicService, result
                assert_equal task_m, result.component_model
                assert_equal "dyn", result.name
            end
            it "should raise if no name has been given" do
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m do
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                end
            end
            it "should raise if no block has been given" do
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m, :as => "dyn"
                end
            end
            it "should raise if no static nor dynamic ports with the required type exist on the task context to fullfill the required service" do
                srv_m = Syskit::DataService.new_submodel { output_port 'out', 'double' }
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m do
                        provides srv_m, "out" => "#{name}_out"
                    end
                end
            end
            it "should accept services that use static ports as well as dynamic ones" do
                srv_m = Syskit::DataService.new_submodel do
                    input_port 'in', 'double'
                    output_port 'out', 'int'
                end
                task_m.dynamic_service srv_m, :as => 'srv' do
                    provides srv_m, "out" => "#{name}_out"
                end
            end
        end

        describe Syskit::Models::Component::DynamicService do
            describe "#instanciate" do
                attr_reader :dyn, :srv_m
                before do
                    srv_m = @srv_m = self.srv_m
                    @dyn = task_m.dynamic_service srv_m, :as => "dyn" do
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                end

                it "should use DynamicServiceInstantiationContext to evaluate the block" do
                    flexmock(Syskit::Models::Component::DynamicServiceInstantiationContext).new_instances.should_receive(:instance_eval).with(Proc).once.pass_thru
                    dyn.instanciate('service_name')
                end
                it "should return the instanciated service" do
                    context = flexmock(Syskit::Models::Component::DynamicServiceInstantiationContext).new_instances
                    context.should_receive(:instance_eval).with(Proc).once
                    context.should_receive(:service).and_return(obj = Object.new)
                    assert_same obj, dyn.instanciate('service_name')
                end
                it "should raise if no service has been defined by the block" do
                    context = flexmock(Syskit::Models::Component::DynamicServiceInstantiationContext).new_instances
                    context.should_receive(:instance_eval).once
                    context.should_receive(:service).once
                    assert_raises(Syskit::InvalidDynamicServiceBlock) { dyn.instanciate('service_name') }
                end
                it "should not allow to have a colliding service name" do
                    task_m.provides Syskit::DataService.new_submodel, :as => 'srv'
                    assert_raises(ArgumentError) { dyn.instanciate('srv') }
                end
                it "should pass the option hash to the dyn service instantiation block" do
                    received_options = nil
                    srv_m = self.srv_m
                    dyn_srv = task_m.dynamic_service srv_m, :as => 'ddd' do
                        received_options = self.options
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                    options = {'test' => 'bla'}
                    dyn_srv.instanciate('srv', options)
                    assert_equal options, received_options
                end
            end
        end
        describe Syskit::Models::Component::DynamicServiceInstantiationContext do
            attr_reader :dyn, :context
            before do
                srv_m = self.srv_m
                @dyn = task_m.dynamic_service srv_m, :as => "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                @context = Syskit::Models::Component::DynamicServiceInstantiationContext.
                    new(task_m, "dyn", dyn)
            end
            describe "#provides" do
                it "should extend the component model's orogen model using #update_component_model_interface and then provide using the resulting port mappings" do
                    srv_m = self.srv_m.new_submodel
                    flexmock(context).should_receive(:update_component_model_interface).
                        with(srv_m, 'out' => 'expected_out').
                        and_return('out' => 'out_port', 'in' => 'in_port')
                    flexmock(task_m).should_receive(:provides).
                        with(srv_m, 'out' => 'out_port', 'in' => 'in_port', :as => 'dyn').
                        and_return(result = Object.new)
                    assert_same result, context.provides(srv_m, 'out' => 'expected_out')
                end
                it "should raise if the given service model does not match the dynamic service model" do
                    srv_m = Syskit::DataService.new_submodel
                    assert_raises(ArgumentError) { context.provides(srv_m, 'out' => 'bla_out', 'in' => 'bla_in') }
                end
                it "should raise if the :as option is given with the wrong name" do
                    assert_raises(ArgumentError) { context.provides(srv_m, :as => 'bla', 'out' => 'bla_out', 'in' => 'bla_in') }
                end
                it "should pass if the :as option is given with the name expected by the instantiation" do
                    context.provides(srv_m, :as => 'dyn', 'out' => 'bla_out', 'in' => 'bla_in')
                end
                it "should raise if #provides has already been called" do
                    context.provides(srv_m, 'out' => 'bla_out', 'in' => 'bla_in')
                    assert_raises(ArgumentError) { context.provides(srv_m, 'out' => 'bla_out', 'in' => 'bla_in') }
                end
            end
            describe "#update_component_model_interface" do
                it "should validate each service port and mapping using #directional_port_mapping and merge" do
                    expected_mappings = Hash['out' => 'bla_out', 'in' => 'bla_in']
                    flexmock(context).should_receive(:directional_port_mapping).with('output', srv_m.out_port, 'explicit_out').
                        once.and_return(expected_mappings['out'])
                    flexmock(context).should_receive(:directional_port_mapping).with('input', srv_m.in_port, nil).
                        once.and_return(expected_mappings['in'])
                    flexmock(Syskit::Models).should_receive(:merge_orogen_task_context_models).
                        with(task_m.orogen_model, [srv_m.orogen_model], expected_mappings).
                        once
                    context.update_component_model_interface(srv_m, 'out' => 'explicit_out')
                end
                it "should return the updated port mappings" do
                    expected_mappings = Hash['out' => 'bla_out', 'in' => 'bla_in']
                    flexmock(context).should_receive(:directional_port_mapping).with('output', srv_m.out_port, 'explicit_out').
                        once.and_return(expected_mappings['out'])
                    flexmock(context).should_receive(:directional_port_mapping).with('input', srv_m.in_port, nil).
                        once.and_return(expected_mappings['in'])
                    flexmock(Syskit::Models).should_receive(:merge_orogen_task_context_models).
                        with(task_m.orogen_model, [srv_m.orogen_model], expected_mappings).
                        once
                    assert_equal expected_mappings, context.update_component_model_interface(srv_m, 'out' => 'explicit_out')
                end
            end
            describe "#directional_port_mapping" do
                attr_reader :task_m, :port, :context
                before do
                    @task_m = flexmock
                    @port = flexmock(:name => 'port_name', :type => Object.new, :type_name => '/bla/type')
                    @context = Syskit::Models::Component::DynamicServiceInstantiationContext.
                        new(task_m, "dyn", nil)
                end

                it "should return the expected name if it is an existing component port" do
                    flexmock(task_m).should_receive(:find_bla_port).with('expected_name').and_return(Object.new)
                    assert_equal 'expected_name', context.directional_port_mapping('bla', port, 'expected_name')
                end
                it "should not test whether an existing component port is a valid dynamic port" do
                    flexmock(task_m).should_receive(:find_bla_port).with('expected_name').and_return(Object.new)
                    flexmock(task_m).should_receive('has_dynamic_bla_port?').never
                    context.directional_port_mapping('bla', port, 'expected_name')
                end
                it "should raise if an implicit mapping is not an existing component port" do
                    flexmock(task_m).should_receive(:find_directional_port_mapping).with('bla', port, nil).and_return(nil)
                    assert_raises(ArgumentError) { context.directional_port_mapping('bla', port, nil) }
                end
                it "should return the expected name if it validates as an existing dynamic port" do
                    flexmock(task_m).should_receive(:find_bla_port).and_return(nil)
                    flexmock(task_m).should_receive(:has_dynamic_bla_port?).with('expected_name', port.type).and_return(true)
                    assert_equal 'expected_name', context.directional_port_mapping('bla', port, 'expected_name')
                end
                it "should raise if the expected name is neither a static port nor a dynamic one" do
                    flexmock(task_m).should_receive(:find_bla_port).and_return(nil)
                    flexmock(task_m).should_receive(:has_dynamic_bla_port?).with('expected_name', port.type).and_return(false)
                    assert_raises(ArgumentError) { context.directional_port_mapping('bla', port, 'expected_name') }
                end
            end
        end
    end

    describe "#self_port_to_component_port" do
        it "should return its argument" do
            task_m = Syskit::TaskContext.new_submodel { output_port 'out', '/int' }
            assert_equal task_m.out_port, task_m.self_port_to_component_port(task_m.out_port)
        end
    end
end

class TC_Models_Component < Test::Unit::TestCase
    include Syskit::SelfTest

    DataService = Syskit::DataService
    TaskContext = Syskit::TaskContext

    def test_new_submodel_registers_the_submodel
        submodel = Component.new_submodel
        subsubmodel = submodel.new_submodel

        assert Component.submodels.include?(submodel)
        assert Component.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_clear_submodels_removes_registered_submodels
        root = Component.new_submodel
        m1 = root.new_submodel
        m2 = root.new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert root.submodels.include?(m1)
        assert root.submodels.include?(m2)
        assert !root.submodels.include?(m11)

        m11 = m1.new_submodel
        root.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !root.submodels.include?(m1)
        assert !root.submodels.include?(m2)
        assert !root.submodels.include?(m11)
    end

    def test_provides
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        bound_service = component.provides service, :as => 'image'

        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, bound_service.port_mappings_for_task)
        assert_equal(service, component.find_data_service('image').model)
    end

    def test_new_submodel_can_give_name_to_anonymous_models
        assert_equal 'C', Component.new_submodel(:name => 'C').name
    end

    def test_short_name_returns_name_if_there_is_one
        assert_equal 'C', Component.new_submodel(:name => 'C').short_name
    end

    def test_short_name_returns_to_s_if_there_are_no_name
        m = Component.new_submodel
        flexmock(m).should_receive(:to_s).and_return("my_name").once
        assert_equal 'my_name', m.short_name
    end

    def test_provides_uses_the_service_name_if_available
        service = DataService.new_submodel(:name => "MyServiceModel")
        component = TaskContext.new_submodel
        srv = component.provides service
        assert_equal "my_service_model", srv.name
    end

    def test_provides_raises_if_the_service_has_no_name_and_none_is_given
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert_raises(ArgumentError) { component.provides(service) }
    end

    def test_find_data_service_returns_nil_on_unknown_service
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        assert(!component.find_data_service('does_not_exist'))
    end

    def test_provides_explicit_name
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        bound_service = component.provides service, :as => 'camera'
        assert_equal(bound_service, component.find_data_service('camera'))
    end

    def test_provides_refuses_to_add_a_service_with_an_existing_name
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'
        assert_raises(ArgumentError) { component.provides(service, :as => 'srv') }
    end

    def test_provides_allows_to_overload_parent_services
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'
        submodel = component.new_submodel
        submodel.provides service, :as => 'srv'
    end

    def test_provides_raises_if_a_service_overload_is_with_an_incompatible_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'

        other_service = DataService.new_submodel
        submodel = component.new_submodel
        assert_raises(ArgumentError) { submodel.provides other_service, :as => 'srv' }
    end

    def test_provides_allows_to_setup_slave_services
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root_srv = component.provides service, :as => 'root'
        slave_srv = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_equal [slave_srv], root_srv.each_slave_data_service.to_a
        assert_same slave_srv, component.find_data_service('root.srv')
    end

    def test_each_slave_data_service
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_equal [slave].to_set, component.each_slave_data_service(root).to_set
    end

    def test_each_slave_data_service_on_submodel
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave = component.provides service, :as => 'srv', :slave_of => 'root'
        component = component.new_submodel
        assert_equal [slave.attach(component)], component.each_slave_data_service(root).to_a
    end

    def test_each_slave_data_service_on_submodel_with_new_slave
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave1 = component.provides service, :as => 'srv1', :slave_of => 'root'
        component = component.new_submodel
        slave2 = component.provides service, :as => 'srv2', :slave_of => 'root'
        assert_equal [slave1.attach(component), slave2].to_a, component.each_slave_data_service(root).sort_by { |srv| srv.full_name }
    end

    def test_slave_can_have_the_same_name_than_a_root_service
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root_srv = component.provides service, :as => 'root'
        srv = component.provides service, :as => 'srv'
        root_srv = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_same srv, component.find_data_service('srv')
        assert_same root_srv, component.find_data_service('root.srv')
    end

    def test_slave_enumeration_includes_parent_slaves_when_adding_a_slave_on_a_child_model
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root = component.provides service, :as => 'root'
        root_srv1 = component.provides service, :as => 'srv1', :slave_of => 'root'

        submodel = component.new_submodel
        root_srv2 = submodel.provides service, :as => 'srv2', :slave_of => 'root'
        assert_equal [root_srv1], component.root_srv.each_slave_data_service.to_a
        assert_equal [root_srv1.attach(submodel), root_srv2], submodel.root_srv.each_slave_data_service.sort_by(&:full_name)
    end

    def test_find_data_service_from_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert(!component.find_data_service_from_type(service))

        bound_service = component.provides service, :as => 'image'
        assert_equal(bound_service, component.find_data_service_from_type(service))

        bound_service = component.provides service, :as => 'camera'
        assert_raises(Syskit::AmbiguousServiceSelection) { component.find_data_service_from_type(service) }
    end

    def test_find_all_data_services_from_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert(component.find_all_data_services_from_type(service).empty?)

        bound_services = Set.new

        bound_services << component.provides(service, :as => 'image')
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)

        bound_services << component.provides(service, :as => 'camera')
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)
    end

    def test_provides_with_port_mappings
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
            output_port 'other', '/int'
        end
        bound_service = component.provides service, 'out' => 'other', :as => 'camera'
        assert_equal(bound_service, component.find_data_service('camera'))
        assert_equal({'out' => 'other'}, bound_service.port_mappings_for_task)
    end

    def test_provides_automatic_mapping_on_type
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/double'
            output_port 'other', '/int'
        end
        bound_service = component.provides service, :as => 'srv'
        assert_equal({'out' => 'other'}, bound_service.port_mappings_for_task)
    end

    def test_provides_validation
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        # No matching port
        component = TaskContext.new_submodel
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Wrong port direction
        component = TaskContext.new_submodel do
            input_port 'out', '/int'
        end
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, no exact match on the name
        component = TaskContext.new_submodel do
            output_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, one of the two possibilites has the wrong
        # direction
        component = TaskContext.new_submodel do
            input_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        bound_service = component.provides(service, :as => 'srv')
        assert_equal({'out' => 'other2'}, bound_service.port_mappings_for_task)

        # Ambiguous type mapping, exact match on the name
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
            output_port 'other2', '/int'
        end
        bound_service = component.provides(service, :as => 'srv')
        assert_equal({'out' => 'out'}, bound_service.port_mappings_for_task)
    end

    def test_has_output_port_returns_false_if_find_returns_false
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_output_port).with('p').and_return(Object.new)
        assert model.has_output_port?('p')
    end

    def test_has_output_port_returns_true_if_find_returns_true
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_output_port).with('p').and_return(nil)
        assert !model.has_output_port?('p')
    end

    def test_has_input_port_returns_false_if_find_returns_false
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_input_port).with('p').and_return(Object.new)
        assert model.has_input_port?('p')
    end

    def test_has_input_port_returns_true_if_find_returns_true
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_input_port).with('p').and_return(nil)
        assert !model.has_input_port?('p')
    end

    def test_find_output_port
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = output_port('p', '/double') }
        p = model.find_output_port('p')
        assert_equal 'p', p.name, 'p'
        assert_equal model, p.component_model
        assert_equal port_model, p.orogen_model
    end

    def test_find_output_port_returns_false_on_outputs
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = input_port('p', '/double') }
        assert !model.find_output_port('p')
    end

    def test_find_output_port_returns_false_on_non_existent_ports
        model = Syskit::TaskContext.new_submodel
        assert !model.find_output_port('p')
    end

    def test_find_input_port
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = input_port('p', '/double') }
        p = model.find_input_port('p')
        assert_equal 'p', p.name, 'p'
        assert_equal model, p.component_model
        assert_equal port_model, p.orogen_model
    end

    def test_find_input_port_returns_false_on_outputs
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = output_port('p', '/double') }
        assert !model.find_input_port('p')
    end

    def test_find_input_port_returns_false_on_non_existent_ports
        model = Syskit::TaskContext.new_submodel
        assert !model.find_input_port('p')
    end

    def test_find_data_service_return_value_is_bound_to_actual_model
        s = DataService.new_submodel
        c = Syskit::TaskContext.new_submodel { provides s, :as => 'srv' }
        sub_c = c.new_submodel
        assert_equal sub_c, sub_c.find_data_service('srv').component_model
    end

    def test_find_data_service_from_type_return_value_is_bound_to_actual_model
        s = DataService.new_submodel
        c = Syskit::TaskContext.new_submodel { provides s, :as => 'srv' }
        sub_c = c.new_submodel
        assert_equal sub_c, sub_c.find_data_service_from_type(s).component_model
    end

    def test_create_proxy_task
        c = Syskit::TaskContext.new_submodel
        task = c.create_proxy_task
        assert_kind_of c, task
        assert task.abstract?
    end
end

