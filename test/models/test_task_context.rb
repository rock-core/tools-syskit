require 'pry'
require 'syskit'
require 'syskit/test'

module DefinitionModule
    # Module used when we want to do some "public" models
end


describe Syskit::Models::TaskContext do
    include Syskit::SelfTest

    after do
        begin DefinitionModule.send(:remove_const, :Task)
        rescue NameError
        end
    end

    describe "#new_submodel" do
        it "allows to set up the orogen interface in the setup block" do
            model = Syskit::TaskContext.new_submodel do
                input_port "port", "int"
                property "property", "int"
            end
            assert(model < Syskit::TaskContext)
            assert(model.orogen_model.find_input_port("port"))
            assert(model.orogen_model.find_property("property"))
        end

        it "allows to set up data services in the setup block" do
            srv = Syskit::DataService.new_submodel
            model = Syskit::TaskContext.new_submodel do
                input_port "port", "int"
                property "property", "int"
                provides srv, :as => 'srv'
            end
            assert(model < Syskit::TaskContext)
            assert model.find_data_service('srv')
        end

        it "registers the created model on parent classes" do
            submodel = Syskit::TaskContext.new_submodel
            subsubmodel = submodel.new_submodel

            assert Syskit::Component.submodels.include?(submodel)
            assert Syskit::Component.submodels.include?(subsubmodel)
            assert Syskit::TaskContext.submodels.include?(submodel)
            assert Syskit::TaskContext.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end

        it "does not register the new models as children of the provided services" do
            submodel = Syskit::TaskContext.new_submodel
            ds = Syskit::DataService.new_submodel
            submodel.provides ds, :as => 'srv'
            subsubmodel = submodel.new_submodel

            assert !ds.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end

        it "registers the oroGen model to syskit model mapping" do
            submodel = Syskit::TaskContext.new_submodel
            assert Syskit::TaskContext.has_model_for?(submodel.orogen_model)
            assert_same submodel, Syskit::TaskContext.model_for(submodel.orogen_model)
        end
    end

    describe "#clear_submodels" do
        it "does not remove models from another branch of the class hierarchy" do
            m1 = Syskit::TaskContext.new_submodel
            m2 = Syskit::TaskContext.new_submodel
            m11 = m1.new_submodel
            m1.clear_submodels
            assert Syskit::Component.submodels.include?(m2)
            assert Syskit::TaskContext.submodels.include?(m2)
        end

        it "deregisters the models on its parent classes as well" do
            m1 = Syskit::TaskContext.new_submodel
            m11 = m1.new_submodel
            m1.clear_submodels

            assert !m1.submodels.include?(m11)
            assert !Syskit::Component.submodels.include?(m11)
            assert !Syskit::TaskContext.submodels.include?(m11)
        end

        it "does not deregisters the receiver" do
            m1 = Syskit::TaskContext.new_submodel
            m11 = m1.new_submodel
            m1.clear_submodels
            assert Syskit::Component.submodels.include?(m1)
            assert Syskit::TaskContext.submodels.include?(m1)
        end

        it "deregisters models on its child classs" do
            m1 = RTT::TaskContext.new_submodel
            assert RTT::TaskContext.submodels.include?(m1)
            m11 = m1.new_submodel
            RTT::TaskContext.clear_submodels
            assert !m1.submodels.include?(m11)
            assert !Syskit::Component.submodels.include?(m1)
            assert !Syskit::TaskContext.submodels.include?(m1)
        end

        it "removes the corresponding orogen to syskit model mapping" do
            submodel = Syskit::TaskContext.new_submodel
            subsubmodel = submodel.new_submodel
            submodel.clear_submodels
            assert !Syskit::TaskContext.has_model_for?(subsubmodel.orogen_model)
        end
    end

    describe "#has_model_for?" do
        it "returns true if the given oroGen model has a corresponding syskit model" do
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "my_project::Task")
            syskit_model = Syskit::TaskContext.define_from_orogen(orogen_model)
            assert Syskit::TaskContext.has_model_for?(orogen_model)
        end
        it "returns false if the given oroGen model does not have a corresponding syskit model" do
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "my_project::Task")
            assert !Syskit::TaskContext.has_model_for?(orogen_model)
        end
    end

    describe "#find_model_from_orogen_name" do
        it "returns the syskit model if there is one for an oroGen model with the given name" do
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "my_project::Task")
            syskit_model = Syskit::TaskContext.define_from_orogen(orogen_model)
            assert_same syskit_model, Syskit::TaskContext.find_model_from_orogen_name("my_project::Task")
        end
        it "returns nil if there is no oroGen model with the given name that has a corresponding syskit model" do
            assert !Syskit::TaskContext.find_model_from_orogen_name("my_project::Task")
        end
    end

    describe "#has_submodel?" do
        it "returns false on unknown orogen models" do
            model = Orocos::Spec::TaskContext.new
            assert !Syskit::TaskContext.has_model_for?(model)
        end
    end

    describe "#model_for" do
        it "raises ArgumentError on unknown orogen models" do
            model = Orocos::Spec::TaskContext.new
            assert_raises(ArgumentError) { Syskit::TaskContext.model_for(model) }
        end
    end

    it "has a proper name if it is assigned as a module's constant" do
        model = Syskit::TaskContext.new_submodel
        DefinitionModule.const_set :Task, model
        assert_equal "DefinitionModule::Task", model.name
    end

    describe "#driver_for" do
        it "creates a new device model if given a string" do
            model = Syskit::TaskContext.new_submodel do
                input_port "port", "int"
                property "property", "int"
            end
            service = model.driver_for "Camera", :as => 'camera'

            device_model = service.model
            assert_equal "Camera", device_model.name
            assert_kind_of Syskit::Models::DeviceModel, device_model
            assert model.fullfills?(device_model)
        end

        it "assigns the newly created model to a constant if called with a string on a component model that is defined in a module" do
            model = Syskit::TaskContext.new_submodel do
                input_port "port", "int"
                property "property", "int"
            end
            DefinitionModule.const_set :Task, model
            model.driver_for "Camera", :as => 'camera'

            assert_kind_of Syskit::Models::DeviceModel, DefinitionModule::Camera
            assert model.fullfills?(DefinitionModule::Camera)
        end
    end

    describe "#define_from_orogen" do
        it "calls new_submodel to create the new model" do
            model = Syskit::TaskContext.new_submodel
            orogen = Orocos::Spec::TaskContext.new
            flexmock(RTT::TaskContext).should_receive(:new_submodel).with(:orogen_model => orogen).once.and_return(model)
            assert_same model, Syskit::TaskContext.define_from_orogen(orogen)
        end

        it "creates the model from the superclass if it does not exist" do
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
    
        it "reuses the model of the superclass if it has already been created" do
            orogen_parent = Orocos::Spec::TaskContext.new
            parent_model = Syskit::TaskContext.define_from_orogen(orogen_parent)

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

        it "properly defines state events" do
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

        it "can register the model as a constant whose name is based on the oroGen model name" do
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "my_project::Task")
            syskit_model = Syskit::TaskContext.define_from_orogen(orogen_model, :register => true)
            assert_same syskit_model, ::MyProject::Task
        end

        it "issues a warning if requested to register a model as a constant that already exists" do
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "definition_module::Task")
            DefinitionModule.const_set(:Task, (obj = Object.new))
            flexmock(Syskit::TaskContext).should_receive(:warn).once
            Syskit::TaskContext.define_from_orogen(orogen_model, :register => true)
        end
        it "refuses to register the model as a constant if the constant already exists" do
            Syskit.logger.level = Logger::FATAL
            orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, "definition_module::Task")
            DefinitionModule.const_set(:Task, (obj = Object.new))
            syskit_model = Syskit::TaskContext.define_from_orogen(orogen_model, :register => true)
            assert_same obj, ::DefinitionModule::Task
            DefinitionModule.send(:remove_const, :Task)
        end
    end

    describe "#instanciate" do
        attr_reader :task_model
        before { @task_model = Syskit::TaskContext.new_submodel }
        it "returns a task using the receiver as model" do
            task = task_model.instanciate(orocos_engine)
            assert_kind_of task_model, task
        end

        it "passes the :task_arguments option as arguments to the newly created task" do
            task = task_model.instanciate(orocos_engine, Syskit::DependencyInjectionContext.new, :task_arguments => {:conf => ['default']})
            assert_equal Hash[:conf => ['default']], task.arguments
        end
        it "sets the fullfilled model properly" do
            arguments = Hash[:conf => ['default']]
            task = task_model.instanciate(orocos_engine, Syskit::DependencyInjectionContext.new, :task_arguments => arguments)
            assert_equal([[task_model], arguments], task.fullfilled_model)
        end
    end
end
