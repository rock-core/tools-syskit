# frozen_string_literal: true

require "syskit/test/self"

describe Syskit do
    describe ".resolve_connections" do
        it "should match ports by name" do
            ports = [["port1", "/type1"], ["port2", "/type2"]]
            out_ports = ports.map { |n, t| flexmock(name: n, type: t) }
            in_ports  = ports.map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[0]], [out_ports[1], in_ports[1]]].to_set,
                         Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should match ports by type" do
            out_ports = [["port1", "/type1"], ["port2", "/type2"]]
                        .map { |n, t| flexmock(name: n, type: t) }
            in_ports = [["port1", "/type2"], ["port2", "/type1"]]
                       .map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[1]], [out_ports[1], in_ports[0]]].to_set,
                         Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should raise AmbiguousAutoConnection if a port-by-type match resolves to multiple inputs" do
            out_ports = [["port1", "/type1"], ["port2", "/type2"]]
                        .map { |n, t| flexmock(name: n, type: t) }
            in_ports = [["in_port1", "/type1"], ["in_port2", "/type1"]]
                       .map { |n, t| flexmock(name: n, type: t) }

            assert_raises(Syskit::AmbiguousAutoConnection) do
                Syskit.resolve_connections(out_ports, in_ports)
            end
        end
        it "should take into account exact matches to resolve ambiguous port-by-type matches" do
            # Important: the exact name match should be second so that we are
            # sure that it is not a fluke due to the order
            out_ports = [["port1", "/type2"], ["port2", "/type2"]]
                        .map { |n, t| flexmock(name: n, type: t) }
            in_ports = [["port1", "/type2"], ["port2", "/type2"]]
                       .map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[0]], [out_ports[1], in_ports[1]]].to_set,
                         Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should raise AmbiguousAutoConnection if more than one output gets connected to a non-multiplexing input" do
            out_ports = [["port1", "/type2"], ["port1", "/type2"]]
                        .map { |n, t| flexmock(name: n, type: t) }
            in_ports = [flexmock(name: "port", type: "/type2", :multiplexes? => false)]

            assert_raises(Syskit::AmbiguousAutoConnection) do
                Syskit.resolve_connections(out_ports, in_ports)
            end
        end
        it "should not raise AmbiguousAutoConnection if more than one output gets connected to a multiplexing input" do
            out_ports = [["port1", "/type2"], ["port2", "/type2"]]
                        .map { |n, t| flexmock(name: n, type: t) }
            in_ports = [flexmock(name: "port", type: "/type2", :multiplexes? => true)]

            Syskit.resolve_connections(out_ports, in_ports)
        end
    end
    describe ".connect" do
        it "should apply the connections as returned by resolve_connections" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to).with(in_port, policy).once
            Syskit.connect(out_port, in_port, policy)
        end
        it "should return the list of created connections" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            assert_equal [[out_port, in_port]], Syskit.connect(out_port, in_port, policy)
        end
        it "should raise InvalidAutoConnection if no matches are found" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([])
            out_port.should_receive(:connect_to).never
            assert_raises(Syskit::InvalidAutoConnection) { Syskit.connect(out_port, in_port, policy) }
        end
        it "should be able to handle a single port as source" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            flexmock(Syskit).should_receive(:resolve_connections).with([out_port], any).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, in_port, policy)
        end
        it "should be able to handle a component as source" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            source = flexmock
            source.should_receive(:each_output_port).and_return(out_port_list = [])
            flexmock(Syskit).should_receive(:resolve_connections).with(out_port_list, [in_port]).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(source, in_port, policy)
        end
        it "should be able to handle a single port as sink" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            flexmock(Syskit).should_receive(:resolve_connections).with(any, [in_port]).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, in_port, policy)
        end
        it "should be able to handle a component as sink" do
            policy = {}
            out_port = flexmock
            in_port = flexmock
            sink = flexmock
            sink.should_receive(:each_input_port).and_return(in_port_list = [])
            flexmock(Syskit).should_receive(:resolve_connections).with([out_port], in_port_list).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, sink, policy)
        end
    end
end
