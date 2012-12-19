require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::Composition do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    describe "state modelling" do
        attr_reader :cmp_model

        before do
            create_simple_composition_model
            @cmp_model = simple_composition_model
            cmp_model.add simple_task_model, :as => 'child'
        end

        #it "allows to use a port from a child as data source" do
        #    cmp_model.state.pose = cmp_model.child_child.out_port

        #    source = cmp_model.state.pose.data_source
        #    assert_equal source, cmp_model.child.out_port
        #    assert_equal source.type, cmp_model.state.pose.type

        #    cmp = instanciate_component(cmp_model)
        #    flexmock(cmp).should_receive(:execute).and_yield
        #    flexmock(cmp).should_receive(:data_reader).with('child', 'out').once.and_return(reader = flexmock)
        #    cmp.resolve_state_sources
        #    assert_equal reader, cmp.state.data_sources.pose.reader
        #end

        #it "allows to use a port from a child's data service as data source" do
        #    cmp_model.state.pose = cmp_model.child_child.srv_srv.srv_out_port

        #    source = cmp_model.state.pose.data_source
        #    assert_equal source, cmp_model.child.out_port
        #    assert_equal source.type, cmp_model.state.pose.type

        #    cmp = instanciate_component(cmp_model)
        #    flexmock(cmp).should_receive(:execute).and_yield
        #    flexmock(cmp).should_receive(:data_reader).with('child', 'out').once.and_return(reader = flexmock)
        #    cmp.resolve_state_sources
        #    assert_equal reader, cmp.state.data_sources.pose.reader
        #end
    end

end
