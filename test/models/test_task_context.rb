require 'pry'
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

    def test_new_submodel_registers_the_submodel_on_parent_classes
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

    def test_new_submodel_registers_the_orogen_model_to_syskit_model_mapping
        submodel = TaskContext.new_submodel
        assert TaskContext.has_model_for?(submodel.orogen_model)
        assert_same submodel, TaskContext.model_for(submodel.orogen_model)
    end

    def test_has_submodel_returns_false_on_unknown_orogen_models
        model = Orocos::Spec::TaskContext.new
        assert !TaskContext.has_model_for?(model)
    end

    def test_model_for_raises_ArgumentError_on_unknown_orogen_models
        model = Orocos::Spec::TaskContext.new
        assert_raises(ArgumentError) { TaskContext.model_for(model) }
    end

    def test_clear_submodels_removes_the_orogen_model_to_syskit_model_mapping
        submodel = TaskContext.new_submodel
        subsubmodel = submodel.new_submodel
        submodel.clear_submodels
        assert !TaskContext.has_model_for?(subsubmodel.orogen_model)
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

    def test_define_from_orogen_registers_the_orogen_to_syskit_mapping
        orogen = Orocos::Spec::TaskContext.new
        model = Syskit::TaskContext.define_from_orogen(orogen)
        assert TaskContext.has_model_for?(orogen)
        assert_same model, TaskContext.model_for(orogen)
    end

    def test_define_from_orogen_creates_superclass_model_as_well
        orogen_parent = Orocos::Spec::TaskContext.new
        orogen = Orocos::Spec::TaskContext.new
        parent_model = Syskit::TaskContext.new_submodel
        orogen.subclasses orogen_parent
        flexmock(Syskit::TaskContext).
            should_receive(:define_from_orogen).with(orogen).
            pass_thru
        flexmock(Syskit::TaskContext).
            should_receive(:define_from_orogen).with(orogen_parent).
            and_return(parent_model)
        model = Syskit::TaskContext.define_from_orogen(orogen)
        assert_same parent_model, model.superclass
    end

    def test_define_from_orogen_reuses_existing_models
        orogen_parent = Orocos::Spec::TaskContext.new
        parent_model = TaskContext.define_from_orogen(orogen_parent)

        orogen = Orocos::Spec::TaskContext.new
        orogen.subclasses orogen_parent
        flexmock(Syskit::TaskContext).
            should_receive(:define_from_orogen).with(orogen).
            pass_thru
        flexmock(Syskit::TaskContext).
            should_receive(:define_from_orogen).with(orogen_parent).
            never.and_return(parent_model)
        model = Syskit::TaskContext.define_from_orogen(orogen)
        assert_same parent_model, model.superclass
    end

    def test_define_from_orogen_propery_defines_state_events
        orogen = Orocos::Spec::TaskContext.new(Orocos.master_project) do
            error_states :CUSTOM_ERROR
            exception_states :CUSTOM_EXCEPTION
            fatal_states :CUSTOM_FATAL
            runtime_states :CUSTOM_RUNTIME
        end
        model = Syskit::TaskContext.define_from_orogen orogen
        assert !model.custom_error_event.terminal?
        assert model.custom_exception_event.terminal?
        assert model.custom_fatal_event.terminal?
        assert !model.custom_runtime_event.terminal?

        plan.add(task = model.new)
        assert task.custom_error_event.child_object?(task.runtime_error_event, Roby::EventStructure::Forwarding)
        assert task.custom_exception_event.child_object?(task.exception_event, Roby::EventStructure::Forwarding)
        assert task.custom_fatal_event.child_object?(task.fatal_error_event, Roby::EventStructure::Forwarding)
    end
end

