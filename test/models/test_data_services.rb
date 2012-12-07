require 'syskit'
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

    def test_new_submodel_registers_the_submodel
        submodel = new_submodel
        assert service_type.submodels.include?(submodel)

        subsubmodel = submodel.new_submodel
        assert service_type.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
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

    def test_clear_submodels_removes_registered_submodels
        m1 = new_submodel
        m2 = new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert service_type.submodels.include?(m1)
        assert service_type.submodels.include?(m2)
        assert !service_type.submodels.include?(m11)

        m11 = m1.new_submodel
        service_type.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !service_type.submodels.include?(m1)
        assert !service_type.submodels.include?(m2)
        assert !service_type.submodels.include?(m11)
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

    def test_new_submodel_requires_constant_name
        assert_raises(ArgumentError) { new_submodel(:name => "image") }
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

    def test_instanciate
        model = data_service_type("A")
        task = model.instanciate(orocos_engine)
        assert_kind_of model.proxy_task_model, task
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
        DataServiceDefinitionTest.send(dsl_service_type_name, "Image", :message_type => '/nil')
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
        assert_raises(ArgumentError) { combus.new_submodel :message_type => '/float' }
    end

    def test_cannot_override_message_type_in_submodel_with_provides
        parent_combus = ComBus.new_submodel :message_type => '/int32_t'
        combus = ComBus.new_submodel { provides parent_combus }
        other_combus = ComBus.new_submodel :message_type => '/double'
        assert_raises(ArgumentError) { combus.provides other_combus }
    end

    def test_cannot_provide_a_combus_that_has_not_the_same_message_type
        combus = ComBus.new_submodel :message_type => '/int'
        other_combus = ComBus.new_submodel :message_type => '/float'
        assert_raises(ArgumentError) { combus.provides other_combus }
    end

    def test_requires_message_type
        assert_raises(ArgumentError) { ComBus.new_submodel }
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
end

