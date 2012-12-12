require 'syskit'
require 'syskit/test'

describe Syskit::Models::Port do
    include Syskit::SelfTest

    describe "#to_component_port" do
        attr_reader :component_model
        before do
            @component_model = Syskit::TaskContext.new_submodel { output_port 'port', '/int' }
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            port_model = Syskit::Models::Port.new(component_model, component_model.orogen_model.find_port('port'))
            flexmock(component_model).should_receive(:self_port_to_component_port).with(port_model).and_return(obj = Object.new).once
            assert_equal obj, port_model.to_component_port
        end
        it "raises ArgumentError if its model does not allow to resolve" do
            port_model = Syskit::Models::Port.new(Object.new, component_model.orogen_model.find_port('port'))
            assert_raises(ArgumentError) { port_model.to_component_port }
        end
    end

end


