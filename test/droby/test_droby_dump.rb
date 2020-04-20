# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module DRoby
        describe V5 do
            attr_reader :local_id, :remote_id, :remote_object_id, :object_manager, :marshal
            before do
                @local_id = Object.new
                @remote_id = Object.new
                @remote_object_id = Object.new
            end

            describe "combus marshalling" do
                attr_reader :combus, :message_type
                before do
                    @object_manager = Roby::DRoby::ObjectManager.new(local_id)
                    @marshal = Roby::DRoby::Marshal.new(object_manager, remote_id)
                    @message_type = stub_type "/Test"
                    @combus = Syskit::ComBus.new_submodel message_type: message_type
                end

                it "marshals the type" do
                    m_combus = marshal.dump(combus)
                    assert_equal "/Test", m_combus.message_type.name
                    assert_equal message_type.to_xml, m_combus.message_type.xml
                end
                it "marshals the lazy_dispatch? flag" do
                    m_combus = marshal.dump(combus)
                    refute m_combus.lazy_dispatch
                    combus.lazy_dispatch = true
                    m_combus = marshal.dump(combus)
                    assert m_combus.lazy_dispatch
                end
            end

            describe "Typelib object marshalling" do
                attr_reader :type
                before do
                    @object_manager = Roby::DRoby::ObjectManager.new(local_id)
                    @marshal = Roby::DRoby::Marshal.new(object_manager, remote_id)
                    @type = Typelib::Registry.new.create_numeric "/Test", 10, :float
                end

                it "marshals both the type and the registry when the type is not known on the peer" do
                    droby = marshal.dump(type)
                    assert_equal "/Test", droby.name
                    assert_equal type.to_xml, droby.xml
                end

                it "marshals the value and the type" do
                    value = type.new
                    droby = marshal.dump(value)
                    assert_equal value.to_byte_array, droby.byte_array
                    assert_equal "/Test", droby.type.name
                    assert_equal type.to_xml, droby.type.xml
                end

                it "updates the peer with the marshalled types" do
                    marshal.dump(type)
                    assert_equal type, object_manager.typelib_registry.get("/Test")
                end

                it "does not re-marshal the same type definition twice" do
                    marshal.dump(type)
                    droby = marshal.dump(type)
                    assert_equal "/Test", droby.name
                    assert !droby.xml
                end
            end

            describe "Typelib object demarshalling" do
                attr_reader :local_id, :remote_id, :remote_object_id, :object_manager, :type, :target_registry

                before do
                    @object_manager = Roby::DRoby::ObjectManager.new(remote_id)
                    @target_registry = object_manager.typelib_registry
                    @marshal = Roby::DRoby::Marshal.new(object_manager, remote_id)
                    @type = Typelib::Registry.new.create_numeric "/Test", 4, :uint
                end

                it "updates the reference registry with the type definition when received" do
                    marshalled   = V5::TypelibTypeModelDumper::DRoby.new("/Test", type.to_xml)
                    unmarshalled = marshal.local_object(marshalled)

                    assert_same target_registry.get("/Test"), unmarshalled
                    refute_same type, unmarshalled
                    assert_equal target_registry.get("/Test"), type
                end

                it "uses the existing type if xml is nil" do
                    marshalled = V5::TypelibTypeModelDumper::DRoby.new("/Test", nil)
                    test_t = target_registry.create_opaque "/Test", 10
                    unmarshalled = marshal.local_object(marshalled)
                    assert_same test_t, unmarshalled
                end

                it "unmarshals the received value" do
                    marshalled = V5::TypelibTypeDumper::DRoby.new(
                        "\xBB\xCC\xDD\x00",
                        V5::TypelibTypeModelDumper::DRoby.new("/Test", type.to_xml)
                    )
                    unmarshalled = marshal.local_object(marshalled)
                    assert_equal 0xDDCCBB, Typelib.to_ruby(unmarshalled)
                end
            end
        end

        describe V5::ProfileDumper do
            describe "an anonymous profile" do
                it "can transfer it" do
                    unmarshalled = droby_transfer(Actions::Profile.new)
                    assert_kind_of Actions::Profile, unmarshalled
                end

                it "creates a new profile each time" do
                    a = droby_transfer(Actions::Profile.new)
                    b = droby_transfer(Actions::Profile.new)
                    refute_same a, b
                end
            end

            describe "a named profile not registered as a constant" do
                it "can transfer it" do
                    unmarshalled = droby_transfer(Actions::Profile.new("AProfile"))
                    assert_kind_of Actions::Profile, unmarshalled
                end
                it "can transfer it even if the name is not a valid constant name" do
                    unmarshalled = droby_transfer(Actions::Profile.new("not_a_valid_constant"))
                    assert_kind_of Actions::Profile, unmarshalled
                end
                it "transfers the name" do
                    unmarshalled = droby_transfer(Actions::Profile.new("AProfile"))
                    assert_equal "AProfile", unmarshalled.name
                end
                it "unmarshals to the same object when the same name is given" do
                    a = droby_transfer(Actions::Profile.new("AProfile"))
                    b = droby_transfer(Actions::Profile.new("AProfile"))
                    assert_same a, b
                end
                it "unmarshals to different objects with different names" do
                    a = droby_transfer(Actions::Profile.new("AProfile"))
                    b = droby_transfer(Actions::Profile.new("AnotherProfile"))
                    refute_same a, b
                end
            end

            describe "a named profile registered as a constant" do
                it "returns the constant" do
                    droby = droby_local_marshaller.dump(Actions::Profile.new("AProfile"))
                    droby = Marshal.load(Marshal.dump(droby))
                    flexmock(droby).should_receive(:constant).with("AProfile")
                                   .and_return(profile = Actions::Profile.new)
                    unmarshalled = droby_remote_marshaller.local_object(droby)
                    assert_same profile, unmarshalled
                end
            end
        end

        describe V5::Models::TaskContextDumper do
            before do
            end

            it "dumps the orogen model and rebuilds the model on the other side" do
                out_t = stub_type "/Test"
                loader = OroGen::Loaders::RTT.new
                loader.register_type_model(out_t)
                project_text = <<-EOPROJECT
                name 'test'
                task_context "Task" do
                    output_port 'out', '/Test'
                end
                EOPROJECT
                loader.project_model_from_text(project_text)
                flexmock(loader).should_receive(:project_model_text_from_name)
                                .with("test").and_return(project_text)

                orogen_model = loader.task_model_from_name("test::Task")
                task_m = Syskit::TaskContext.define_from_orogen(orogen_model, register: false)
                unmarshalled = droby_transfer task_m
                assert_equal "/Test", unmarshalled.out_port.type.name
            end

            it "return an already existing oroGen model" do
                local_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                Roby.app.default_loader.register_task_context_model(local_model)
                remote_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                task_m = Syskit::TaskContext.new_submodel(orogen_model: remote_model)
                assert_same local_model, droby_transfer(task_m).orogen_model
            end

            it "return an already existing oroGen/Syskit model pair" do
                local_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                Roby.app.default_loader.register_task_context_model(local_model)
                local_task_m = Syskit::TaskContext.define_from_orogen(local_model, register: false)

                remote_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                remote_task_m = Syskit::TaskContext.new_submodel(orogen_model: remote_model)
                assert_same local_task_m, droby_transfer(remote_task_m)
            end

            it "returns the same model once reconstructed" do
                orogen_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                task_m = Syskit::TaskContext.new_submodel(orogen_model: orogen_model)
                unmarshalled = droby_transfer task_m
                assert_same unmarshalled, droby_transfer(task_m)
            end

            it "gracefully handles models that do not have a textual representation" do
                loader = OroGen::Loaders::RTT.new
                project_text = <<-EOPROJECT
                name 'test'
                task_context "Task" do
                end
                EOPROJECT
                loader.project_model_from_text(project_text)

                orogen_model = loader.task_model_from_name("test::Task")
                task_m = Syskit::TaskContext.define_from_orogen(orogen_model, register: false)
                unmarshalled = droby_transfer task_m
                assert_equal "test::Task", unmarshalled.orogen_model.name
            end

            it "gracefully handles models that do not have a real backing project" do
                orogen_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "test::Task")
                task_m = Syskit::TaskContext.new_submodel(orogen_model: orogen_model)
                unmarshalled = droby_transfer task_m
                assert_equal "test::Task", unmarshalled.orogen_model.name
            end

            it "gracefully handles anonymous models" do
                orogen_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, nil)
                task_m = Syskit::TaskContext.new_submodel(orogen_model: orogen_model)
                unmarshalled = droby_transfer task_m
            end

            it "gracefully handles submodels of anonymous models" do
                orogen_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, nil)
                task_m = Syskit::TaskContext.new_submodel(orogen_model: orogen_model)
                subtask_m = task_m.new_submodel
                unmarshalled = droby_transfer subtask_m
                assert_same droby_transfer(task_m), unmarshalled.superclass
            end

            it "gracefully handles ruby task contexts" do
                # This is a regression test, that is also covered by the anonymous
                # tests above. The problems related to anonymous tests have been
                # detected because of issues with RubyTaskContext
                task_m = RubyTaskContext.new_submodel
                unmarshalled = droby_transfer task_m
                assert_same RubyTaskContext, unmarshalled.superclass
            end

            it "marshals and unmarshals the superclasses" do
                parent_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "parent::Task")
                parent_m = Syskit::TaskContext.new_submodel(orogen_model: parent_model)

                child_model = OroGen::Spec::TaskContext.new(
                    app.default_orogen_project, "child::Task",
                    subclasses: parent_model
                )
                child_m = parent_m.new_submodel(orogen_model: child_model)

                unmarshalled = droby_transfer child_m
                assert_equal "parent::Task", unmarshalled.supermodel.orogen_model.name
                assert_equal "child::Task", unmarshalled.orogen_model.name
                assert_same unmarshalled.supermodel.orogen_model,
                            unmarshalled.orogen_model.superclass
            end

            it "deals with types shared between the superclass and the subclass" do
                parent_model = OroGen::Spec::TaskContext.new(app.default_orogen_project, "parent::Task")
                parent_model.output_port "out", stub_type("/test")
                parent_m = Syskit::TaskContext.new_submodel(orogen_model: parent_model)

                child_model = OroGen::Spec::TaskContext.new(
                    app.default_orogen_project, "child::Task",
                    subclasses: parent_model
                )
                child_model.output_port "out2", stub_type("/test")
                child_m = parent_m.new_submodel(orogen_model: child_model)

                droby_transfer child_m
                assert droby_remote_marshaller.object_manager.typelib_registry.include?("/test")
            end
        end
    end
end
