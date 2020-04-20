# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe OroGenNamespace do
        before do
            @object = Module.new
            @object.extend OroGenNamespace
            @constant_registration = OroGen.syskit_model_constant_registration?
            OroGen.syskit_model_constant_registration = false
        end

        after do
            OroGen.syskit_model_constant_registration = @constant_registration
        end

        it "gives access to a registered model by method calls" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            assert_same obj, @object.project.Task
        end

        it "handles namespaces in the component name" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::test::Task"
                )
            )
            @object.register_syskit_model(obj)
            assert_same obj, @object.project.test.Task
        end

        it "raises if given arguments" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            e = assert_raises(ArgumentError) do
                @object.project.Task("something")
            end
            assert_equal "expected 0 arguments, got 1", e.message
        end

        it "raises if resolving a task that does not exist" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            e = assert_raises(NoMethodError) do
                @object.project.Other
            end
            assert_equal "no task Other on project, available tasks: Task", e.message
        end

        it "allows to resolve a project by its orogen name" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            assert_same obj, @object.syskit_model_by_orogen_name("project::Task")
        end

        it "raises if resolving a project that does not exist" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            e = assert_raises(NoMethodError) do
                @object.does_not_exist.Other
            end
            assert_equal(
                "undefined method `does_not_exist' for #{@object}, "\
                "available OroGen projects: project",
                e.message
            )
        end

        it "does not register a model by constant by default" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            refute @object.const_defined?(:Project)
        end

        it "registers a model by constant by CamelCasing it if enabled" do
            @object.syskit_model_constant_registration = true
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            @object.register_syskit_model(obj)
            assert @object.const_defined?(:Project)
            assert_same obj, @object::Project::Task
        end

        it "returns the call chain that leads to the model" do
            flexmock(@object, name: "test")
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: "project"),
                    name: "project::Task"
                )
            )
            assert_equal "test.project.Task", @object.register_syskit_model(obj)
        end

        describe OroGenNamespace::DeploymentNamespace do
            before do
                @m = OroGenNamespace::DeploymentNamespace.new
            end

            after do
                @m.clear
            end

            it "resolves a given model through method call" do
                syskit_m = Deployment.new_submodel(name: "blablabla")
                @m.register_syskit_model(syskit_m)
                assert_equal syskit_m, @m.blablabla
            end

            it "reports the list of available models on NoMethodError" do
                @m.register_syskit_model(Deployment.new_submodel(name: "depl1"))
                @m.register_syskit_model(Deployment.new_submodel(name: "depl2"))
                e = assert_raises(NoMethodError) do
                    @m.does_not_exist
                end
                assert_equal(
                    "no deployment registered with the name 'does_not_exist', "\
                    "available deployments are: depl1, depl2",
                    e.message
                )
            end

            describe "constant registration" do
                it "registers the deployments as constants on ::Deployments if "\
                   "OroGen.syskit_model_constant_registration is set" do
                    OroGen.syskit_model_constant_registration = true
                    depl_m = Deployment.new_submodel(name: "depl")
                    @m.register_syskit_model(depl_m)
                    assert_same depl_m, ::Deployments::Depl
                end

                it "clears the registered constants on clear" do
                    OroGen.syskit_model_constant_registration = true
                    depl_m = Deployment.new_submodel(name: "depl")
                    @m.register_syskit_model(depl_m)
                    @m.clear
                    refute ::Deployments.const_defined?(:Depl)
                end
            end
        end
    end
end
