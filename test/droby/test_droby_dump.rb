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
    end
end

