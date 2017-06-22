require 'syskit/test/self'

module Syskit
    module DRoby
        describe "Typelib object marshalling" do
            attr_reader :local_id, :remote_id, :remote_object_id, :object_manager, :type

            before do
                @local_id = Object.new
                @remote_id = Object.new
                @remote_object_id = Object.new
                @object_manager = Roby::DRoby::ObjectManager.new(local_id)
                @type = Typelib::Registry.new.create_numeric '/Test', 10, :float
            end

            subject { Roby::DRoby::Marshal.new(object_manager, remote_id) }

            it "marshals both the type and the registry when the type is not known on the peer" do
                droby = subject.dump(type)
                assert_equal '/Test', droby.name
                assert_equal type.to_xml, droby.xml
            end

            it "marshals the value and the type" do
                value = type.new
                droby = subject.dump(value)
                assert_equal value.to_byte_array, droby.byte_array
                assert_equal '/Test', droby.type.name
                assert_equal type.to_xml, droby.type.xml
            end

            it "updates the peer with the marshalled types" do
                subject.dump(type)
                assert_equal type, object_manager.typelib_registry.get('/Test')
            end

            it "does not re-marshal the same type definition twice" do
                subject.dump(type)
                droby = subject.dump(type)
                assert_equal '/Test', droby.name
                assert !droby.xml
            end
        end

        describe "Typelib object demarshalling" do
            attr_reader :local_id, :remote_id, :remote_object_id, :object_manager, :type, :target_registry

            before do
                @local_id = Object.new
                @remote_id = Object.new
                @remote_object_id = Object.new
                @object_manager = Roby::DRoby::ObjectManager.new(remote_id)
                @target_registry = object_manager.typelib_registry
                @type = Typelib::Registry.new.create_numeric '/Test', 4, :uint
            end

            subject { Roby::DRoby::Marshal.new(object_manager, local_id) }

            it "updates the reference registry with the type definition when received" do
                marshalled   = V5::TypelibTypeModelDumper::DRoby.new('/Test', type.to_xml)
                unmarshalled = subject.local_object(marshalled)

                assert_same target_registry.get('/Test'), unmarshalled
                refute_same type, unmarshalled
                assert_equal target_registry.get('/Test'), type
            end

            it "uses the existing type if xml is nil" do
                marshalled   = V5::TypelibTypeModelDumper::DRoby.new('/Test', nil)
                test_t = target_registry.create_opaque '/Test', 10
                unmarshalled = subject.local_object(marshalled)
                assert_same test_t, unmarshalled
            end

            it "unmarshals the received value" do
                marshalled   = V5::TypelibTypeDumper::DRoby.new(
                    "\xBB\xCC\xDD\x00",
                    V5::TypelibTypeModelDumper::DRoby.new('/Test', type.to_xml))
                unmarshalled = subject.local_object(marshalled)
                assert_equal 0xDDCCBB, Typelib.to_ruby(unmarshalled)
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
                    flexmock(droby).should_receive(:constant).with('AProfile').
                        and_return(profile = Actions::Profile.new)
                    unmarshalled = droby_remote_marshaller.local_object(droby)
                    assert_same profile, unmarshalled
                end
            end
        end
    end
end

