# frozen_string_literal: true

require "syskit/test/self"

module OroGen
    module DefinitionModule
        # Module used when we want to do some "public" models
    end
end

module Syskit # :nodoc:
    describe Models::TaskContext do
        before do
            @model_toplevel_constant_registration = OroGen.syskit_model_toplevel_constant_registration?
            @model_constant_registration = OroGen.syskit_model_constant_registration?

            OroGen.syskit_model_toplevel_constant_registration = false
            OroGen.syskit_model_constant_registration = false
        end
        after do
            OroGen.syskit_model_toplevel_constant_registration = @model_toplevel_constant_registration
            OroGen.syskit_model_constant_registration = @model_constant_registration
            TaskContext.clear_submodels
        end

        describe "the root models" do
            it "resolves toplevel events" do
                assert_equal :exception, TaskContext.find_state_event(:EXCEPTION)
            end

            it "does not define an event for PRE_OPERATIONAL" do
                assert_nil TaskContext.find_state_event(:PRE_OPERATIONAL)
            end
        end

        describe "specialized models" do
            it "has an isolated orogen model" do
                model = TaskContext.new_submodel
                spec_m = model.specialize
                assert_same spec_m.orogen_model.superclass, model.orogen_model
                spec_m.orogen_model.output_port "p", "/double"
                assert !model.orogen_model.has_port?("p")
            end
        end

        describe "#new_submodel" do
            it "allows to set up the orogen interface in the setup block" do
                model = TaskContext.new_submodel do
                    input_port "port", "int"
                    property "property", "int"
                end
                assert(model < TaskContext)
                assert(model.orogen_model.find_input_port("port"))
                assert(model.orogen_model.find_property("property"))
            end

            it "allows to set up data services in the setup block" do
                srv = DataService.new_submodel
                model = TaskContext.new_submodel do
                    input_port "port", "int"
                    property "property", "int"
                    provides srv, as: "srv"
                end
                assert(model < TaskContext)
                assert model.find_data_service("srv")
            end

            it "allows to set up custom states in the setup block" do
                model = TaskContext.new_submodel do
                    runtime_states :CUSTOM
                end
                assert_equal :custom, model.find_state_event(:CUSTOM)
            end

            it "gives access to state events from parent models" do
                parent_m = TaskContext.new_submodel do
                    runtime_states :CUSTOM
                end
                child_m = parent_m.new_submodel
                assert_equal :custom, child_m.find_state_event(:CUSTOM)
            end

            it "registers the created model on parent classes" do
                submodel = TaskContext.new_submodel
                subsubmodel = submodel.new_submodel

                assert Component.has_submodel?(submodel)
                assert Component.has_submodel?(subsubmodel)
                assert TaskContext.has_submodel?(submodel)
                assert TaskContext.has_submodel?(subsubmodel)
                assert submodel.has_submodel?(subsubmodel)
            end

            it "does not register the new models as children of the provided services" do
                submodel = TaskContext.new_submodel
                ds = DataService.new_submodel
                submodel.provides ds, as: "srv"
                subsubmodel = submodel.new_submodel

                assert !ds.has_submodel?(subsubmodel)
                assert submodel.has_submodel?(subsubmodel)
            end

            it "registers the oroGen model to syskit model mapping" do
                submodel = TaskContext.new_submodel
                assert TaskContext.has_model_for?(submodel.orogen_model)
                assert_same submodel, TaskContext.model_for(submodel.orogen_model)
            end
        end

        describe "#clear_submodels" do
            it "does not remove models from another branch of the class hierarchy" do
                m1 = TaskContext.new_submodel
                m2 = TaskContext.new_submodel
                m11 = m1.new_submodel
                m1.clear_submodels
                assert Component.has_submodel?(m2)
                assert TaskContext.has_submodel?(m2)
            end

            it "deregisters the models on its parent classes as well" do
                m1 = TaskContext.new_submodel
                m11 = m1.new_submodel
                m1.clear_submodels

                assert !m1.has_submodel?(m11)
                assert !Component.has_submodel?(m11)
                assert !TaskContext.has_submodel?(m11)
            end

            it "does not deregisters the receiver" do
                m1 = TaskContext.new_submodel
                m11 = m1.new_submodel
                m1.clear_submodels
                assert Component.has_submodel?(m1)
                assert TaskContext.has_submodel?(m1)
            end

            it "deregisters models on its child classs" do
                m1 = OroGen::RTT::TaskContext.new_submodel
                assert OroGen::RTT::TaskContext.has_submodel?(m1)
                m11 = m1.new_submodel
                OroGen::RTT::TaskContext.clear_submodels
                assert !m1.has_submodel?(m11)
                assert !Component.has_submodel?(m1)
                assert !TaskContext.has_submodel?(m1)
            end

            it "removes the corresponding orogen to syskit model mapping" do
                submodel = TaskContext.new_submodel
                subsubmodel = submodel.new_submodel
                submodel.clear_submodels
                assert !TaskContext.has_model_for?(subsubmodel.orogen_model)
            end
        end

        describe "#has_model_for?" do
            it "returns true if the given oroGen model has a corresponding syskit model" do
                orogen_model = Models.create_orogen_task_context_model("my_project::Task")
                syskit_model = TaskContext.define_from_orogen(orogen_model)
                assert TaskContext.has_model_for?(orogen_model)
            end
            it "returns false if the given oroGen model does not have a corresponding syskit model" do
                orogen_model = Models.create_orogen_task_context_model("my_project::Task")
                assert !TaskContext.has_model_for?(orogen_model)
            end
        end

        describe "#find_model_from_orogen_name" do
            it "returns the syskit model if there is one for an oroGen model with the given name" do
                orogen_model = Models.create_orogen_task_context_model("my_project::Task")
                syskit_model = TaskContext.define_from_orogen(orogen_model)
                assert_same syskit_model, TaskContext.find_model_from_orogen_name("my_project::Task")
            end
            it "returns nil if there is no oroGen model with the given name that has a corresponding syskit model" do
                assert !TaskContext.find_model_from_orogen_name("my_project::Task")
            end
        end

        describe "#has_submodel?" do
            it "returns false on unknown orogen models" do
                model = Models.create_orogen_task_context_model
                assert !TaskContext.has_model_for?(model)
            end
        end

        describe "#find_model_by_orogen" do
            it "returns nil on unknown orogen models" do
                model = Models.create_orogen_task_context_model
                assert !TaskContext.find_model_by_orogen(model)
            end
        end

        describe "#model_for" do
            it "raises ArgumentError on unknown orogen models" do
                model = Models.create_orogen_task_context_model
                assert_raises(ArgumentError) { TaskContext.model_for(model) }
            end
        end

        describe "backward-compatible constant registration behavior" do
            before do
                OroGen.syskit_model_constant_registration = true
            end

            it "registers the model as a constant whose name is based on the oroGen model name, under OroGen" do
                orogen_model = Models.create_orogen_task_context_model("my_project::Task")
                syskit_model = TaskContext.define_from_orogen(orogen_model, register: true)
                assert_same syskit_model, OroGen::MyProject::Task
            end

            describe "toplevel registration" do
                before do
                    OroGen.syskit_model_toplevel_constant_registration = true
                end

                it "registers the model as a global constant whose name is based on the oroGen model name" do
                    orogen_model = Models.create_orogen_task_context_model("my_project::Task")
                    syskit_model =
                        TaskContext.define_from_orogen(orogen_model, register: true)

                    capture_log(Syskit, :fatal) do
                        assert_same syskit_model, ::MyProject::Task
                    end
                end
            end

            describe "conflict with already existing constants" do
                before do
                    OroGen.syskit_model_constant_registration = true
                end
                after do
                    OroGen::DefinitionModule.send(:remove_const, :Task)
                end

                it "issues a warning if requested to register a model as a constant that already exists" do
                    orogen_model = Models.create_orogen_task_context_model("definition_module::Task")
                    OroGen::DefinitionModule.const_set(:Task, (obj = Object.new))
                    flexmock(TaskContext).should_receive(:warn).once
                    TaskContext.define_from_orogen(orogen_model, register: true)
                end
                it "refuses to register the model as a constant if the constant already exists" do
                    Syskit.logger.level = Logger::FATAL
                    orogen_model = Models.create_orogen_task_context_model("definition_module::Task")
                    OroGen::DefinitionModule.const_set(:Task, (obj = Object.new))
                    flexmock(TaskContext).should_receive(:warn).once
                    syskit_model = TaskContext.define_from_orogen(orogen_model, register: true)
                    assert_same obj, ::OroGen::DefinitionModule::Task
                end
            end

            it "#clear_submodels removes the corresponding constants" do
                submodel = TaskContext.new_submodel
                OroGen::DefinitionModule.const_set(:Task, submodel)
                TaskContext.clear_submodels
                refute OroGen::DefinitionModule.const_defined_here?(:Task)
            end
        end

        describe "#define_from_orogen" do
            it "calls new_submodel to create the new model" do
                model = TaskContext.new_submodel
                orogen = Models.create_orogen_task_context_model
                flexmock(OroGen::RTT::TaskContext)
                    .should_receive(:new_submodel)
                    .with(orogen_model: orogen).once.and_return(model)
                assert_same model, TaskContext.define_from_orogen(orogen)
            end

            it "passes arbitrary keyword options to new_submodel" do
                model = TaskContext.new_submodel
                orogen = Models.create_orogen_task_context_model
                flexmock(OroGen::RTT::TaskContext)
                    .should_receive(:new_submodel)
                    .with(orogen_model: orogen, some: "option").once.and_return(model)
                assert_same model, TaskContext.define_from_orogen(orogen, some: "option")
            end

            it "sets the model name to the OroGen call chain" do
                project = OroGen::Spec::Project.new(app.default_loader)
                project.name "test"
                orogen = OroGen::Spec::TaskContext.new(project, "test::Task")
                TaskContext.define_from_orogen(orogen, register: true)
                assert_equal "OroGen.test.Task", OroGen.test.Task.name
            end

            it "registers the model on the OroGen namespace" do
                project = OroGen::Spec::Project.new(app.default_loader)
                project.name "test"
                orogen = OroGen::Spec::TaskContext.new(project, "test::Task")
                TaskContext.define_from_orogen(orogen, register: true)
                assert_same orogen, OroGen.test.Task.orogen_model
            end

            it "allows changing how the registration is done by overloading register_model" do
                orogen_namespace = Module.new do
                    extend OroGenNamespace
                end
                klass = Class.new(TaskContext) do
                    singleton_class.class_eval do
                        define_method :register_model do
                            orogen_namespace.register_syskit_model(self)
                        end
                    end
                end

                project = OroGen::Spec::Project.new(app.default_loader)
                project.name "test"
                orogen = OroGen::Spec::TaskContext.new(project, "test::Task")
                klass.define_from_orogen(orogen, register: true)
                assert_same orogen, orogen_namespace.test.Task.orogen_model
                refute OroGen.project_name?("test")
            end

            it "creates the model from the superclass if it does not exist" do
                orogen_parent = Models.create_orogen_task_context_model
                orogen = Models.create_orogen_task_context_model(subclasses: orogen_parent)
                parent_model = TaskContext.new_submodel
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen).with(orogen, register: false)
                    .pass_thru
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen).with(orogen_parent, register: false)
                    .and_return(parent_model)
                model = TaskContext.define_from_orogen(orogen, register: false)
                assert_same parent_model, model.superclass
            end

            it "uses an explicit supermodel if one is given" do
                orogen_parent = Models.create_orogen_task_context_model
                orogen = Models.create_orogen_task_context_model(subclasses: orogen_parent)
                parent_model = TaskContext.new_submodel
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen)
                    .with(orogen, any)
                    .pass_thru
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen)
                    .with(orogen_parent, register: false)
                    .never
                model = TaskContext.define_from_orogen(
                    orogen, supermodel: parent_model, register: false
                )
                assert_same parent_model, model.superclass
            end

            it "reuses the model of the superclass if it has already been created" do
                orogen_parent = Models.create_orogen_task_context_model
                parent_model = TaskContext.define_from_orogen(orogen_parent)

                orogen = Models.create_orogen_task_context_model(subclasses: orogen_parent)
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen).with(orogen)
                    .pass_thru
                flexmock(TaskContext)
                    .should_receive(:define_from_orogen).with(orogen_parent)
                    .never.and_return(parent_model)
                model = TaskContext.define_from_orogen(orogen)
                assert_same parent_model, model.superclass
            end

            it "properly defines state events" do
                orogen = Models.create_orogen_task_context_model
                orogen.error_states :CUSTOM_ERROR
                orogen.exception_states :CUSTOM_EXCEPTION
                orogen.fatal_states :CUSTOM_FATAL
                orogen.runtime_states :CUSTOM_RUNTIME

                model = TaskContext.define_from_orogen orogen
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

        describe "#instanciate" do
            attr_reader :task_model
            before { @task_model = TaskContext.new_submodel }
            it "returns a task using the receiver as model" do
                task = task_model.instanciate(plan)
                assert_kind_of task_model, task
            end

            it "passes the :task_arguments option as arguments to the newly created task" do
                task = task_model.instanciate(plan, DependencyInjectionContext.new, task_arguments: { conf: ["default"] })
                assert_equal Hash[conf: ["default"], read_only: Roby::DefaultArgument.new(false)], task.arguments
            end
            it "sets the fullfilled model properly" do
                arguments = Hash[conf: ["default"]]
                task = task_model.instanciate(plan, DependencyInjectionContext.new, task_arguments: arguments)
                assert_equal([[task_model], arguments], task.fullfilled_model)
            end
        end

        describe "#has_dynamic_input_port?" do
            attr_reader :task_m, :opaque_t, :intermediate_t
            before do
                typekit = Models.create_orogen_typekit_model("test")
                opaque_t = typekit.create_interface_opaque "/opaque", 0
                intermediate_t = typekit.create_null "/intermediate"
                typekit.opaques << OroGen::Spec::OpaqueDefinition.new(opaque_t, intermediate_t.name, {}, nil)
                app.default_loader.register_typekit_model(typekit)
                @opaque_t = app.default_loader.resolve_type "/opaque"
                @intermediate_t = app.default_loader.resolve_type "/intermediate"

                @task_m = TaskContext.new_submodel do
                    dynamic_input_port "test", "/opaque"
                end
            end
            it "should convert the given type into the orocos type name before checking for existence" do
                flexmock(task_m.orogen_model).should_receive(:has_dynamic_input_port?).once
                                             .with("test", opaque_t).pass_thru
                assert task_m.has_dynamic_input_port?("test", intermediate_t)
            end
        end

        describe "#has_dynamic_output_port?" do
            attr_reader :task_m, :opaque_t, :intermediate_t
            before do
                typekit = Models.create_orogen_typekit_model("test")
                opaque_t = typekit.create_interface_opaque "/opaque", 0
                intermediate_t = typekit.create_null "/intermediate"
                typekit.opaques << OroGen::Spec::OpaqueDefinition.new(opaque_t, intermediate_t.name, {}, nil)
                app.default_loader.register_typekit_model(typekit)
                @opaque_t = app.default_loader.resolve_type "/opaque"
                @intermediate_t = app.default_loader.resolve_type "/intermediate"

                @task_m = TaskContext.new_submodel do
                    dynamic_output_port "test", "/opaque"
                end
            end
            it "should convert the given type into the orocos type name before checking for existence" do
                flexmock(task_m.orogen_model).should_receive(:has_dynamic_output_port?).once
                                             .with("test", opaque_t).pass_thru
                assert task_m.has_dynamic_output_port?("test", intermediate_t)
            end
        end

        describe "Port#connected?" do
            it "returns false" do
                m0 = TaskContext.new_submodel do
                    output_port "out", "int"
                end
                m1 = TaskContext.new_submodel do
                    input_port "in", "int"
                end
                assert !m0.out_port.connected_to?(m1.in_port)
            end
        end

        describe "#configuration_manager" do
            it "inherits the manager from the underlying concrete model" do
                task_m = TaskContext.new_submodel
                assert_same task_m.configuration_manager,
                            task_m.specialize.configuration_manager
            end
        end

        describe "attribute access through method missing" do
            before do
                @task_m = TaskContext.new_submodel do
                    output_port "out_p", "/double"
                end
            end
            it "responds to a known port" do
                assert @task_m.respond_to?(:out_p_port)
            end
            it "does not respond to a unknown port" do
                refute @task_m.respond_to?(:does_not_exist_port)
            end
        end

        describe "#deployed_as" do
            before do
                @loader = OroGen::Loaders::Base.new
                @task_m = task_m = TaskContext.new_submodel(
                    orogen_model_name: "test::Task"
                )
                default_name = OroGen::Spec::Project.default_deployment_name("test::Task")
                @default_deployment_name = default_name
                @deployment_m = Deployment.new_submodel(name: "test_deployment") do
                    task default_name, task_m
                end
                flexmock(@loader).should_receive(:deployment_model_from_name)
                                 .with(default_name)
                                 .and_return(@deployment_m.orogen_model)
            end

            def self.common_behavior(c)
                c.it "uses the default deployment using the given name" do
                    task = @task_m.new
                    candidates = @ir
                                 .deployment_group
                                 .find_all_suitable_deployments_for(task)

                    assert_equal 1, candidates.size
                    c = candidates.first
                    assert_equal "test", c.mapped_task_name
                    assert_equal(
                        { @default_deployment_name => "test",
                          "#{@default_deployment_name}_Logger" => "test_Logger" },
                        c.configured_deployment.name_mappings
                    )
                end
            end

            describe "called on the task model" do
                before do
                    @ir = @task_m.deployed_as("test", loader: @loader)
                end

                common_behavior(self)
            end

            describe "called on a specialized submodel" do
                before do
                    @ir = @task_m.specialize.deployed_as("test", loader: @loader)
                end

                common_behavior(self)
            end

            describe "called on InstanceRequirements" do
                before do
                    @ir = InstanceRequirements
                          .new([@task_m])
                          .deployed_as("test", loader: @loader)
                end

                common_behavior(self)
            end

            describe "called on InstanceRequirements for a specialized submodel" do
                before do
                    @ir = InstanceRequirements
                          .new([@task_m.specialize])
                          .deployed_as("test", loader: @loader)
                end

                common_behavior(self)
            end
        end

        describe "#deployed_as_unmanaged" do
            before do
                @task_m = TaskContext.new_submodel(
                    orogen_model_name: "test::Task"
                )
                @conf = RobyApp::Configuration.new(Roby.app)
                register_unmanaged_manager("unmanaged_tasks", conf: @conf)
            end

            def self.common_behavior(c)
                c.it "declares an unmanaged deployment of the given task model" do
                    task = @task_m.new
                    candidates = @ir
                                 .deployment_group
                                 .find_all_suitable_deployments_for(task)

                    assert_equal 1, candidates.size
                    deployed_task = candidates.first
                    configured_deployment = deployed_task.configured_deployment
                    # This is the real thing ... Other than the process server,
                    # everything looks exactly the same
                    assert_equal "unmanaged_tasks",
                                 configured_deployment.process_server_name
                    assert_match(/Unmanaged/, configured_deployment.model.name)
                    assert_equal "test", deployed_task.mapped_task_name
                    assert_equal(
                        { "test" => "test" },
                        configured_deployment.name_mappings
                    )
                end
            end

            describe "called on the task model" do
                before do
                    @ir = @task_m.deployed_as_unmanaged("test", process_managers: @conf)
                end

                common_behavior(self)
            end

            describe "called on a specialized submodel" do
                before do
                    @ir = @task_m.specialize
                                 .deployed_as_unmanaged("test", process_managers: @conf)
                end

                common_behavior(self)
            end

            describe "called on InstanceRequirements" do
                before do
                    @ir = InstanceRequirements
                          .new([@task_m])
                          .deployed_as_unmanaged("test", process_managers: @conf)
                end

                common_behavior(self)
            end

            describe "called on InstanceRequirements for a specialized submodel" do
                before do
                    @ir = InstanceRequirements
                          .new([@task_m.specialize])
                          .deployed_as_unmanaged("test", process_managers: @conf)
                end

                common_behavior(self)
            end
        end

        # Control of the update_properties backward-compatible behavior
        describe "#use_update_properties?" do
            it "returns true for a plain submodel of TaskContext" do
                assert TaskContext.new_submodel.use_update_properties?
            end

            it "returns false if the submodel defines #configure" do
                task_m = TaskContext.new_submodel
                task_m.class_eval { def configure; end }
                refute task_m.use_update_properties?
            end

            it "ignores an update_properties methods defined by a module injected in "\
            "the hierarchy" do
                task_m = TaskContext.new_submodel
                task_m.class_eval { def configure; end }
                mod = Module.new { def update_properties; end }
                task_m.prepend mod
                refute task_m.use_update_properties?
            end

            it "returns true if the submodel defines #update_properties" do
                task_m = TaskContext.new_submodel
                task_m.class_eval { def update_properties; end }
                assert task_m.use_update_properties?
            end

            it "returns true if the submodel defines both #configure and "\
            "#update_properties" do
                task_m = TaskContext.new_submodel
                task_m.class_eval do
                    def update_properties; end

                    def configure; end
                end
                assert task_m.use_update_properties?
            end
        end
    end
end
