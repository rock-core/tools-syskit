require 'syskit/test/self'

module Syskit
    describe OroGenNamespace do
        before do
            @object = Module.new
            @object.extend OroGenNamespace
        end

        it "gives access to a registered model by method calls" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: 'project'),
                    name: 'project::Task'))
            @object.register_syskit_model(obj)
            assert_same obj, @object.project.Task
        end

        it "raises if attempting to register a model whose project name does not match" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: 'test'),
                    name: 'project::Task'))
            assert_raises(ArgumentError) do
                @object.register_syskit_model(obj)
            end
        end

        it "allows to resolve a project by its orogen name" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: 'project'),
                    name: 'project::Task'))
            @object.register_syskit_model(obj)
            assert_same obj, @object.syskit_model_by_orogen_name('project::Task')
        end

        it "does not register a model by constant by default" do
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: 'project'),
                    name: 'project::Task'))
            @object.register_syskit_model(obj)
            refute @object.const_defined?(:Project)
        end

        it "registers a model by constant by CamelCasing it if enabled" do
            @object.syskit_model_constant_registration = true
            obj = flexmock(
                orogen_model: flexmock(
                    project: flexmock(name: 'project'),
                    name: 'project::Task'))
            @object.register_syskit_model(obj)
            assert @object.const_defined?(:Project)
            assert_same obj, @object::Project::Task
        end
    end
end
