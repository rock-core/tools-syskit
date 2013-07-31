require 'syskit/test'

module Test_DataServiceModel
    include Syskit::SelfTest

    attr_reader :service_type
    attr_reader :dsl_service_type_name

    DataServiceModel = Syskit::Models::DataServiceModel

    def teardown
        super
        begin DataServiceDefinitionTest.send(:remove_const, :Image)
        rescue NameError
        end
    end

    def new_submodel(*args, &block)
        service_type.new_submodel(*args, &block)
    end

    def test_data_services_are_registered_as_submodels_of_task_service
        srv = Syskit::DataService.new_submodel
        assert Roby::TaskService.each_submodel.to_a.include?(srv)
    end

    def test_new_submodel_can_give_name_to_anonymous_models
        assert_equal 'Srv', new_submodel(:name => 'Srv').name
    end

    def test_short_name_returns_name_if_there_is_one
        assert_equal 'Srv', new_submodel(:name => 'Srv').short_name
    end

    def test_short_name_returns_to_s_if_there_are_no_name
        m = new_submodel
        flexmock(m).should_receive(:to_s).and_return("my_name").once
        assert_equal 'my_name', m.short_name
    end

    def test_new_submodel_without_name
        model = new_submodel
        assert_kind_of(DataServiceModel, model)
        assert(model < service_type)
        assert(!model.name)
    end

    def test_new_submodel_with_name
        model = new_submodel(:name => "Image")
        assert_kind_of(DataServiceModel, model)
        assert(model < service_type)
        assert_equal("Image", model.name)
    end

    module DataServiceDefinitionTest
    end

    def test_module_dsl_service_type_definition_requires_valid_name
        assert_raises(ArgumentError) { DataServiceDefinitionTest.send(dsl_service_type_name, 'Srv::Image') }
        assert_raises(ArgumentError) { DataServiceDefinitionTest.send(dsl_service_type_name, 'image') }
    end

    def test_proxy_task_model
        model = new_submodel
        proxy_model = model.proxy_task_model
        assert(proxy_model <= TaskContext)
        assert(proxy_model.fullfills?(model))
        assert_equal([model], proxy_model.proxied_data_services.to_a)
    end

    def test_proxy_task_model_caches_model
        model = new_submodel
        proxy_model = model.proxy_task_model
        assert_same proxy_model, model.proxy_task_model
    end

    def test_model_output_port
        model = new_submodel do
	    input_port 'in', 'double'
	    output_port 'out', 'int32_t'
	end
	assert_equal('/int32_t', model.find_output_port('out').type.name)
	assert_equal(nil, model.find_output_port('does_not_exist'))
	assert_equal(nil, model.find_output_port('in'))
    end

    def test_model_input_port
        model = new_submodel do
	    input_port 'in', 'double'
	    output_port 'out', 'int32_t'
	end
	assert_equal('/double', model.find_input_port('in').type.name)
	assert_equal(nil, model.find_input_port('out'))
	assert_equal(nil, model.find_input_port('does_not_exist'))
    end

    def test_provides
        parent_model = new_submodel
        model = new_submodel
        model.provides parent_model
        assert(model.fullfills?(parent_model))
        assert(model.parent_models.include?(parent_model))
    end

    def test_provides_ports
        parent_model = new_submodel do
            output_port "out", "/int"
        end
        model = new_submodel
        model.provides parent_model
        assert(model.find_output_port("out"))
        assert(model.fullfills?(parent_model))

        assert_equal({"out" => "out"}, model.port_mappings_for(parent_model))
        assert_equal({"out" => "out"},
                     model.port_mappings_for(model))
    end

    def test_provides_port_mappings_for_is_transitive
        base = new_submodel do
            output_port "base", "/int"
            output_port 'base_unmapped', '/double'
        end
        parent = new_submodel do
            output_port "parent", "/int"
            output_port 'parent_unmapped', '/double'
        end
        parent.provides base, 'base' => 'parent'
        model = new_submodel do
            output_port "model", "/int"
        end
        model.provides parent, 'parent' => 'model'

        assert_equal({'parent' => 'model',
                      'base_unmapped' => 'base_unmapped',
                      'parent_unmapped' => 'parent_unmapped'}, model.port_mappings_for(parent))
        assert_equal({'base' => 'model',
                      'base_unmapped' => 'base_unmapped'}, model.port_mappings_for(base))
    end

    def test_provides_port_collision
        parent_model = new_submodel do
            output_port "out", "/int"
        end

        model = new_submodel do
            output_port "out", "/double"
        end
        assert_raises(Syskit::SpecError) { model.provides parent_model }

        model = new_submodel do
            output_port "out", "/double"
        end
        assert_raises(Syskit::SpecError) { model.provides parent_model }

        model = new_submodel do
            input_port "out", "/int"
        end
        assert_raises(Syskit::SpecError) { model.provides parent_model }
    end

    def test_provides_with_port_mappings
        parent_model = new_submodel do
            output_port "out", "/int"
        end
        model = new_submodel do
            output_port "new_out", "/int"
        end
        model.provides parent_model, 'out' => 'new_out'
        assert(!model.find_output_port("out"))
        assert(model.find_output_port("new_out"))
        assert(model.fullfills?(parent_model))

        assert_equal({"out" => "new_out"}, model.port_mappings_for(parent_model))
        assert_equal({"new_out" => "new_out"},
                     model.port_mappings_for(model))
    end

    def test_provides_port_mapping_validation
        parent_model = new_submodel do
            output_port "out", "/int"
        end

        model = new_submodel do
            output_port "new_out", "/double"
        end
        assert_raises(Syskit::SpecError) { model.provides(parent_model, 'out' => 'new_out') }
        assert_raises(Syskit::SpecError) { model.provides(parent_model, 'out' => 'really_new_out') }
        assert_raises(Syskit::SpecError) { model.provides(parent_model, 'old_out' => 'new_out') }

        model = new_submodel do
            output_port "new_out", "/double"
        end
        assert_raises(Syskit::SpecError) { model.provides(parent_model, 'out' => 'new_out') }

        model = new_submodel do
            input_port "new_out", "/int"
        end
        assert_raises(Syskit::SpecError) { model.provides(parent_model, 'out' => 'new_out') }
    end

    def test_provides_can_override_port_using_port_mappings
        parent_model = new_submodel do
            output_port "out", "/int32_t"
        end

        model = new_submodel do
            output_port "out", "/double"
            output_port "new_out", "/int32_t"
        end
        model.provides(parent_model, 'out' => 'new_out')

        assert_equal("/double", model.find_output_port('out').type_name)
        assert_equal("/int32_t", model.find_output_port('new_out').type_name)

        assert_equal({"out" => "new_out"}, model.port_mappings_for(parent_model))
        assert_equal({"out" => "out", "new_out" => "new_out"},
                     model.port_mappings_for(model))
    end

    def test_create_proxy_task
        model = data_service_type("A")
        task = model.create_proxy_task
        assert task.abstract?
        assert_kind_of model.proxy_task_model, task
    end

    def test_instanciate
        model = data_service_type("A")
        task = model.instanciate(plan)
        assert_kind_of model.proxy_task_model, task
    end

    def test_it_can_be_droby_marshalled_and_unmarshalled
        model = data_service_type("A")
        loaded = Marshal.load(Marshal.dump(model.droby_dump(nil)))
        loaded = loaded.proxy(Roby::Distributed::DumbManager)
        assert_equal model.name, loaded.name
    end
end

class TC_Models_DataService < Test::Unit::TestCase
    include Test_DataServiceModel

    def setup
        @service_type = Syskit::DataService
        @dsl_service_type_name = :data_service_type
        super
    end

    def test_each_fullfilled_model
        parent_model = new_submodel
        assert_equal [parent_model, service_type].to_set, parent_model.each_fullfilled_model.to_set
        child_model = new_submodel do
            provides parent_model
        end
        assert_equal [parent_model, child_model, service_type].to_set, child_model.each_fullfilled_model.to_set
    end

    def test_module_dsl_service_type_definition
        DataServiceDefinitionTest.send(dsl_service_type_name, "Image")
        srv = DataServiceDefinitionTest::Image
        assert_equal "Test_DataServiceModel::DataServiceDefinitionTest::Image", srv.name
    end

    def test_cannot_provide_combus
        srv = Syskit::DataService.new_submodel
        combus = Syskit::ComBus.new_submodel :message_type => '/int'
        assert_raises(ArgumentError) { srv.provides combus }
    end

    def test_cannot_provide_device
        srv = Syskit::DataService.new_submodel
        combus = Syskit::Device.new_submodel
        assert_raises(ArgumentError) { srv.provides combus }
    end

    def test_it_is_registered_as_a_submodel_of_TaskService
        srv = Syskit::DataService.new_submodel
        assert Roby::TaskService.each_submodel.to_a.include?(srv)
    end
end

class TC_Models_Device < Test::Unit::TestCase
    include Test_DataServiceModel

    def setup
        @service_type = Syskit::Device
        @dsl_service_type_name = :device_type
        super
    end

    def test_each_fullfilled_model
        parent_model = new_submodel
        assert_equal [parent_model, service_type, Syskit::DataService].to_set, parent_model.each_fullfilled_model.to_set
        child_model = new_submodel do
            provides parent_model
        end
        assert_equal [parent_model, child_model, service_type, Syskit::DataService].to_set, child_model.each_fullfilled_model.to_set
    end

    def test_module_dsl_service_type_definition
        DataServiceDefinitionTest.send(dsl_service_type_name, "Image")
        srv = DataServiceDefinitionTest::Image
        assert_equal "Test_DataServiceModel::DataServiceDefinitionTest::Image", srv.name
    end

    def test_cannot_provide_combus
        srv = Syskit::Device.new_submodel
        combus = Syskit::ComBus.new_submodel :message_type => '/int'
        assert_raises(ArgumentError) { srv.provides combus }
    end

    def test_it_is_registered_as_a_submodel_of_TaskService
        device = Syskit::Device.new_submodel
        assert Roby::TaskService.each_submodel.to_a.include?(device)
    end
end

class TC_Models_ComBus < Test::Unit::TestCase
    include Test_DataServiceModel

    def setup
        @service_type = Syskit::ComBus
        @dsl_service_type_name = :com_bus_type
        super
    end

    def test_each_fullfilled_model
        parent_model = new_submodel
        assert_equal [parent_model, service_type, Syskit::Device, Syskit::DataService].to_set, parent_model.each_fullfilled_model.to_set
        child_model = new_submodel do
            provides parent_model
        end
        assert_equal [parent_model, child_model, service_type, Syskit::Device, Syskit::DataService].to_set, child_model.each_fullfilled_model.to_set
    end

    def new_submodel(options = Hash.new, &block)
        options = Kernel.validate_options options,
            :name => nil, :message_type => '/int'
        Syskit::ComBus.new_submodel(options, &block)
    end

    def test_module_dsl_service_type_definition
        DataServiceDefinitionTest.com_bus_type "Image", :message_type => '/double'
        srv = DataServiceDefinitionTest::Image
        assert_equal "Test_DataServiceModel::DataServiceDefinitionTest::Image", srv.name
    end

    def test_can_set_message_type_directly
        combus = ComBus.new_submodel :message_type => '/int32_t'
        assert_equal '/int32_t', combus.message_type
    end

    def test_can_set_message_type_with_provides
        parent_combus = ComBus.new_submodel :message_type => '/int32_t'
        combus = ComBus.new_submodel { provides parent_combus }
        assert_equal '/int32_t', combus.message_type
    end

    def test_cannot_override_message_type_in_submodel_directly
        combus = ComBus.new_submodel :message_type => '/int'
        assert_raises(ArgumentError) { combus.new_submodel :message_type => '/double' }
    end

    def test_cannot_override_message_type_in_submodel_with_provides
        parent_combus = ComBus.new_submodel :message_type => '/int32_t'
        combus = ComBus.new_submodel { provides parent_combus }
        other_combus = ComBus.new_submodel :message_type => '/double'
        assert_raises(ArgumentError) { combus.provides other_combus }
    end

    def test_cannot_provide_a_combus_that_has_not_the_same_message_type
        combus = ComBus.new_submodel :message_type => '/int'
        other_combus = ComBus.new_submodel :message_type => '/double'
        assert_raises(ArgumentError) { combus.provides other_combus }
    end

    def test_requires_message_type
        assert_raises(ArgumentError) { ComBus.new_submodel }
    end

    def test_defines_client_in_srv
        combus = ComBus.new_submodel :message_type => '/int'
        assert combus.client_in_srv
    end
    def test_defines_client_out_srv
        combus = ComBus.new_submodel :message_type => '/int'
        assert combus.client_out_srv
    end
    def test_defines_bus_in_srv
        combus = ComBus.new_submodel :message_type => '/int'
        assert combus.bus_in_srv
    end
    def test_defines_bus_out_srv
        combus = ComBus.new_submodel :message_type => '/int'
        assert combus.bus_out_srv
    end
end

describe Syskit::ComBus do
    include Test_DataServiceModel

    def new_submodel(options = Hash.new, &block)
        options = Kernel.validate_options options,
            :name => nil, :message_type => '/int'
        Syskit::ComBus.new_submodel(options, &block)
    end


    def setup
        @service_type = Syskit::ComBus
        @dsl_service_type_name = :com_bus_type
        super
    end

    # This is important for reloading: the reloading code calls
    # ExistingComBusModule.provides Syskit::ComBus
    it "can provide Syskit::ComBus" do
        m = new_submodel
        m.clear_model
        m.provides Syskit::ComBus
    end

    it "is registered as a submodel of Roby::TaskService" do
        combus = Syskit::ComBus.new_submodel :message_type => '/int'
        assert Roby::TaskService.each_submodel.to_a.include?(combus)
    end

    it "declares the necesary dynamic service when provided on its driver" do
        combus = Syskit::ComBus.new_submodel :message_type => '/int'
        driver_m = Syskit::TaskContext.new_submodel
        flexmock(combus).should_receive(:dynamic_service_name).and_return('dyn_srv')
        flexmock(driver_m).should_receive(:dynamic_service).with(combus.bus_base_srv, Hash[:as => 'dyn_srv'], Proc).once
        driver_m.provides combus, :as => 'name'
    end

    describe "the dynamic service definition" do
        attr_reader :combus_m, :driver_m
        before do
            @combus_m = Syskit::ComBus.new_submodel :message_type => '/double'
            @driver_m = Syskit::TaskContext.new_submodel do
                dynamic_input_port /\w+/, '/double'
                dynamic_output_port /\w+/, '/double'
            end
            flexmock(combus_m).should_receive(:dynamic_service_name).and_return('dyn_srv')
            driver_m.driver_for combus_m, :as => 'combus_driver'
        end
        it "instanciates an input bus service if requested one" do
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'in')
            assert_same combus_m.bus_in_srv, srv.model.model
        end
        it "provides the mapping of from_bus to input_name_for if requested an input service" do
            flexmock(combus_m).should_receive(:input_name_for).with('dev').and_return('in_DEV')
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'in')
            assert_equal Hash['to_bus' => 'in_DEV'], srv.model.port_mappings_for_task
        end
        it "instanciates an output bus service if requested one" do
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'out')
            assert_same combus_m.bus_out_srv, srv.model.model
        end
        it "provides the mapping of from_bus to output_name_for if requested an output service" do
            flexmock(combus_m).should_receive(:output_name_for).with('dev').and_return('out_DEV')
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'out')
            assert_equal Hash['from_bus' => 'out_DEV'], srv.model.port_mappings_for_task
        end
        it "instanciates bidirectional service if requested one" do
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'inout')
            assert_same combus_m.bus_srv, srv.model.model
        end
        it "provides the proper mappings if requested a bidirectional service" do
            flexmock(combus_m).should_receive(:output_name_for).with('dev').and_return('out_DEV')
            flexmock(combus_m).should_receive(:input_name_for).with('dev').and_return('in_DEV')
            srv = driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'inout')
            assert_equal Hash['from_bus' => 'out_DEV', 'to_bus' => 'in_DEV'], srv.model.port_mappings_for_task
        end
        it "raises if the :direction option is invalid" do
            assert_raises(ArgumentError) do
                driver_m.new.require_dynamic_service('dyn_srv', :as => 'dev', :direction => 'bla')
            end
        end
    end

    describe "#extend_attached_device_configuration" do
        it "can be called from within the definition block" do
            com_bus = Syskit::ComBus.new_submodel :message_type => '/double' do
                extend_attached_device_configuration do
                    def m; end
                end
            end
            assert com_bus.attached_device_configuration_module.instance_methods.include?(:m)
        end
    end
end
