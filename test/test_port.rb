require 'syskit'
require 'syskit/test'

describe Syskit::Models::Port do
    include Syskit::SelfTest

    describe "#to_component_port" do
        attr_reader :component, :port
        before do
            component_model = Syskit::TaskContext.new_submodel { output_port 'port', '/int' }
            port_model = Syskit::Models::Port.new(component_model, component_model.orogen_model.find_port('port'))
            @component = component_model.new
            @port = component.port_port
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            flexmock(component).should_receive(:self_port_to_component_port).with(port).and_return(obj = Object.new).once
            assert_equal obj, port.to_component_port
        end
        it "raises ArgumentError if its model does not allow to resolve" do
            port = Syskit::Port.new(component.model.port_port, Object.new)
            assert_raises(ArgumentError) { port.to_component_port }
        end
    end
end

