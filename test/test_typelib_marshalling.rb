require 'syskit/test'

describe Syskit::TypelibMarshalling do
    include Syskit::SelfTest

    attr_reader :type, :value, :registry, :peer

    before do
        @registry = Typelib::CXXRegistry.new
        flexmock(Syskit::TypelibMarshalling).should_receive(:reference_registry).and_return(registry).by_default
        @type = registry.create_compound '/Test' do |c|
            c.field = '/double'
        end
        @value = type.new
        value.field = 10

        peer_m = Class.new do
            def incremental_dump?(object); false end
        end
        peer_m.include Syskit::TypelibMarshalling::DRobyPeerExtension
        @peer = peer_m.new
    end

    describe "marshalling" do
        it "should marshal both the type and the registry when the type is not known on the peer" do
            droby = Roby::Distributed.format(type, peer)
            assert_equal '/Test', droby.name
            assert_equal type.to_xml, droby.xml
        end

        it "should update the peer with the marshalled types" do
            Roby::Distributed.format(type, peer)
            assert_equal value.class, peer.registry.get('/Test')
        end

        it "should not re-marshal the same type definition twice" do
            Roby::Distributed.format(type, peer)
            droby = Roby::Distributed.format(type, peer)
            assert !droby.xml
        end
    end

    describe "demarshalling" do
        attr_reader :droby_complete, :droby_partial, :target_registry

        before do
            value.field = 42
            @droby_complete = Roby::Distributed.format(value, peer)
            @droby_partial = Roby::Distributed.format(value, peer)
            @target_registry = Typelib::Registry.new
            flexmock(Syskit::TypelibMarshalling).should_receive(:reference_registry).and_return(target_registry)
        end

        it "should update the reference registry with the type definition when received" do
            unmarshalled = droby_complete.type.proxy(Roby::Distributed::DumbManager)
            assert(unmarshalled <= Typelib::CompoundType)
            assert_same target_registry.get('/Test'), unmarshalled
        end

        it "should use the existing type if xml is nil" do
            test_t = target_registry.create_opaque '/Test', 10
            unmarshalled = droby_partial.type.proxy(Roby::Distributed::DumbManager)
            assert_same test_t, unmarshalled
        end

        it "should unmarshal the received value" do
            unmarshalled = droby_complete.proxy(Roby::Distributed::DumbManager)
            assert_in_delta 42, unmarshalled.field, 0.0001
        end
    end
end

