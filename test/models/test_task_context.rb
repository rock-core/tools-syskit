require 'syskit'
require 'syskit/test'

class TC_Models_TaskContext < Test::Unit::TestCase
    include Syskit::SelfTest

    module DefinitionModule
        # Module used when we want to do some "public" models
    end

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def teardown
        super
        begin DefinitionModule.send(:remove_const, :Task)
        rescue NameError
        end
    end

    def test_new_submodel
        model = TaskContext.new_submodel do
            input_port "port", "int"
            property "property", "int"
        end
        assert(model < Syskit::TaskContext)
        assert(model.orogen_model.find_input_port("port"))
        assert(model.orogen_model.find_property("property"))
    end

    def test_new_submodel_registers_the_submodel
        submodel = TaskContext.new_submodel
        subsubmodel = submodel.new_submodel

        assert Component.submodels.include?(submodel)
        assert Component.submodels.include?(subsubmodel)
        assert TaskContext.submodels.include?(submodel)
        assert TaskContext.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_clear_submodels_removes_registered_submodels
        m1 = TaskContext.new_submodel
        m2 = TaskContext.new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert Component.submodels.include?(m1)
        assert TaskContext.submodels.include?(m1)
        assert Component.submodels.include?(m2)
        assert TaskContext.submodels.include?(m2)
        assert !Component.submodels.include?(m11)
        assert !TaskContext.submodels.include?(m11)

        m11 = m1.new_submodel
        TaskContext.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !Component.submodels.include?(m1)
        assert !TaskContext.submodels.include?(m1)
        assert !Component.submodels.include?(m2)
        assert !TaskContext.submodels.include?(m2)
        assert !Component.submodels.include?(m11)
        assert !TaskContext.submodels.include?(m11)
    end

    def test_new_submodel_does_not_register_the_submodels_on_provided_services
        submodel = TaskContext.new_submodel
        ds = DataService.new_submodel
        submodel.provides ds, :as => 'srv'
        subsubmodel = submodel.new_submodel

        assert !ds.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_task_context_definition_on_modules
        model = TaskContext.new_submodel
        DefinitionModule.const_set :Task, model
        assert_equal "TC_Models_TaskContext::DefinitionModule::Task", model.name
    end

    def test_driver_for_on_anonymous_task
        model = TaskContext.new_submodel do
            input_port "port", "int"
            property "property", "int"
        end
        service = model.driver_for "Camera"

        device_model = service.model
        assert_equal "Camera", device_model.name
        assert_kind_of Syskit::Models::DeviceModel, device_model
        assert model.fullfills?(device_model)
    end

    def test_driver_for_on_assigned_tasks
        model = TaskContext.new_submodel do
            input_port "port", "int"
            property "property", "int"
        end
        DefinitionModule.const_set :Task, model
        model.driver_for "Camera"

        assert_kind_of Syskit::Models::DeviceModel, DefinitionModule::Camera
        assert model.fullfills?(DefinitionModule::Camera)
    end
end


