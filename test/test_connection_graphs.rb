require 'syskit/test/self'

module Syskit
    describe ConnectionGraph do
        subject { ConnectionGraph.new }
        let(:source_m) do
            Syskit::TaskContext.new_submodel do
                output_port 'out1', '/double'
                output_port 'out2', '/double'
            end
        end
        let(:sink_m) do
            Syskit::TaskContext.new_submodel do
                input_port 'in1', '/double'
                input_port 'in2', '/double'
            end
        end
        attr_reader :source, :sink
        before do
            plan.add(@source = source_m.new)
            plan.add(@sink = sink_m.new)
        end
        
        describe "#add_edge" do
            it "raises if trying to add an edge without mappings" do
                assert_raises(ArgumentError) do
                    subject.add_edge(source, sink, Hash.new)
                end
            end
            it "allows to add new connections to an existing edge" do
                subject.add_edge(source, sink,
                    ['out1', 'in1'] => Hash.new)
                subject.add_edge(source, sink,
                    ['out2', 'in2'] => Hash.new)
                assert_equal Hash[['out1', 'in1'] => Hash.new, ['out2', 'in2'] => Hash.new],
                    subject.edge_info(source, sink)
            end
            it "raises if trying to change the policy of an existing connection" do
                subject.add_edge(source, sink,
                    ['out1', 'in1'] => Hash.new)
                assert_raises(ArgumentError) do
                    subject.add_edge(source, sink,
                        ['out1', 'in1'] => Hash[buffer: 10])
                end
                assert_equal Hash[['out1', 'in1'] => Hash.new],
                    subject.edge_info(source, sink)
            end
        end

        describe "#has_out_connections?" do
            it "returns false for unconnected tasks" do
                assert !subject.has_out_connections?(source, 'out1')
            end
            it "returns false for tasks that have connections, but not of the required out port" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert !subject.has_out_connections?(source, 'out2')
            end
            it "returns true for tasks that have connections for the required out port" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert subject.has_out_connections?(source, 'out1')
            end
        end

        describe "#has_in_connections?" do
            it "returns false for unconnected tasks" do
                assert !subject.has_in_connections?(sink, 'in1')
            end
            it "returns false for tasks that have connections, but not of the required in port" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert !subject.has_in_connections?(sink, 'in2')
            end
            it "returns true for tasks that have connections for the required in port" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert subject.has_in_connections?(sink, 'in1')
            end
        end

        describe "#connected?" do
            it "returns false for unconnected tasks" do
                assert !subject.connected?(source, 'out1', sink, 'in1')
            end
            it "returns false for tasks that have connections, but not the required one" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert !subject.connected?(source, 'out1', sink, 'in2')
            end
            it "returns true for tasks that have connections for the required in port" do
                subject.add_connections(source, sink, ['out1', 'in1'] => Hash.new)
                assert subject.connected?(source, 'out1', sink, 'in1')
            end
        end

        describe "#each_in_connection" do
            it "yields nothing if there are no input connections" do
                assert subject.each_in_connection(sink).to_a.empty?
            end
            it "enumerates the required connections" do
                subject.add_connections(source, sink,
                    ['out1', 'in1'] => Hash.new,
                    ['out2', 'in1'] => Hash.new,
                    ['out2', 'in2'] => Hash.new)
                assert_equal [[source, 'out1', 'in1', Hash.new], [source, 'out2', 'in1', Hash.new], [source, 'out2', 'in2', Hash.new]],
                    subject.each_in_connection(sink).to_a
            end
            it "restricts itself to the given port" do
                subject.add_connections(source, sink,
                    ['out1', 'in1'] => Hash.new,
                    ['out2', 'in1'] => Hash.new,
                    ['out2', 'in2'] => Hash.new)
                assert_equal [[source, 'out2', 'in2', Hash.new]],
                    subject.each_in_connection(sink, 'in2').to_a
            end
        end

        describe "#each_out_connection" do
            it "yields nothing if there are no output connections" do
                assert subject.each_in_connection(source).to_a.empty?
            end
            it "enumerates the required connections" do
                subject.add_connections(source, sink,
                    ['out1', 'in1'] => Hash.new,
                    ['out2', 'in1'] => Hash.new,
                    ['out2', 'in2'] => Hash.new)
                assert_equal [['out1', 'in1', sink, Hash.new], ['out2', 'in1', sink, Hash.new], ['out2', 'in2', sink, Hash.new]],
                    subject.each_out_connection(source).to_a
            end
            it "restricts itself to the given port" do
                subject.add_connections(source, sink,
                    ['out1', 'in1'] => Hash.new,
                    ['out2', 'in1'] => Hash.new,
                    ['out2', 'in2'] => Hash.new)
                assert_equal [['out2', 'in1', sink, Hash.new], ['out2', 'in2', sink, Hash.new]],
                    subject.each_out_connection(source, 'out2').to_a
            end
        end

        describe "#remove_connections" do
            it "deregisters the requested connections from the current edge info" do
                subject.add_connections(source, sink,
                    ['out1', 'in1'] => Hash.new,
                    ['out2', 'in1'] => Hash.new,
                    ['out2', 'in2'] => Hash.new)
                subject.remove_connections(source, sink, [['out2', 'in1']])
                assert_equal Hash[['out1', 'in1'] => Hash.new, ['out2', 'in2'] => Hash.new],
                    subject.edge_info(source, sink)
            end
            it "removes the edge if the remaining mappings are empty" do
                plan.add(source2 = source_m.new)
                plan.add(sink2 = sink_m.new)
                subject.add_connections(source,  sink,  ['out1', 'in1'] => Hash.new)
                subject.add_connections(source2, sink,  ['out1', 'in1'] => Hash.new)
                subject.add_connections(source,  sink2, ['out1', 'in1'] => Hash.new)
                subject.remove_connections(source, sink, [['out1', 'in1']])
                assert !subject.has_edge?(source, sink)
            end
            it "removes the source if it is ends up being connected to nothing" do
                plan.add(source2 = source_m.new)
                subject.add_connections(source,  sink, ['out1', 'in1'] => Hash.new)
                subject.add_connections(source2, sink, ['out1', 'in1'] => Hash.new)

                subject.remove_connections(source, sink, [['out1', 'in1']])
                assert !subject.has_vertex?(source)
                assert subject.has_vertex?(sink)
            end
            it "removes the sink if it is ends up being connected to nothing" do
                plan.add(sink2 = sink_m.new)
                subject.add_connections(source, sink,  ['out1', 'in1'] => Hash.new)
                subject.add_connections(source, sink2, ['out1', 'in1'] => Hash.new)
                subject.remove_connections(source, sink, [['out1', 'in1']])
                assert subject.has_vertex?(source)
                assert !subject.has_vertex?(sink)
            end
        end
    end

    describe Flows::DataFlow do
        subject { plan.task_relation_graph_for(Flows::DataFlow) }
        let(:task_m) do
            Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
                output_port 'out', '/double'
            end
        end
        let(:cmp_m) do
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: 'test'
            cmp_m.export cmp_m.test_child.in_port
            cmp_m.export cmp_m.test_child.out_port
            cmp_m
        end

        attr_reader :tasks, :cmp
        before do
            @cmp   = Array.new
            @tasks = Array.new
            4.times do |i|
                cmp[i] = cmp_m.instanciate(plan)
                tasks[i] = cmp[i].test_child
            end
        end
        
        describe "#each_concrete_in_connection" do
            it "yields nothing if there are no input connections" do
                assert subject.each_concrete_in_connection(tasks[0]).to_a.empty?
            end
            it "enumerates the connection until a task context" do
                cmp[1].out_port.connect_to   tasks[0].in_port
                tasks[2].out_port.connect_to tasks[0].in_port
                cmp[3].out_port.connect_to   cmp[0].in_port
                assert_equal Set[[tasks[1], 'out', 'in', Hash.new],
                                 [tasks[2], 'out', 'in', Hash.new],
                                 [tasks[3], 'out', 'in', Hash.new]],
                    subject.each_concrete_in_connection(tasks[0]).to_set
            end
            it "ignores a connection to a composition whose port is not forwarded" do
                cmp[1].out_port.connect_to tasks[0].in_port
                cmp[1].test_child.remove_sink(cmp[1])
                assert_equal [], subject.each_concrete_in_connection(tasks[0]).to_a
            end
        end

        describe "#each_out_connection" do
            it "yields nothing if there are no connections" do
                assert subject.each_concrete_out_connection(tasks[0]).to_a.empty?
            end
            it "enumerates the connection until a task context" do
                tasks[0].out_port.connect_to tasks[1].in_port
                tasks[0].out_port.connect_to cmp[2].in_port
                cmp[0].out_port.connect_to   cmp[3].in_port
                assert_equal Set[['out', 'in', tasks[1], Hash.new],
                                 ['out', 'in', tasks[2], Hash.new],
                                 ['out', 'in', tasks[3], Hash.new]],
                    subject.each_concrete_out_connection(tasks[0]).to_set
            end
            it "ignores a connection to a composition whose port is not forwarded" do
                tasks[0].out_port.connect_to cmp[1].in_port
                cmp[1].remove_sink(cmp[1].test_child)
                assert_equal [], subject.each_concrete_out_connection(tasks[0]).to_a
            end
        end

        describe "transaction-related behaviour" do
            attr_reader :source, :sink
            before do
                @source = tasks[0]
                @sink   = tasks[1]
            end
            it "keeps an adition within the transaction boundaries" do
                plan.in_transaction do |trsc|
                    trsc[source].out_port.connect_to trsc[sink].in_port
                    assert trsc[source].out_port.connected_to?(trsc[sink].in_port)
                    assert !source.out_port.connected_to?(sink.in_port)
                    trsc.commit_transaction
                end
                assert source.out_port.connected_to?(sink.in_port)
            end
            it "keeps a removal within the transaction boundaries" do
                source.out_port.connect_to sink.in_port
                plan.in_transaction do |trsc|
                    trsc[source].out_port.disconnect_from trsc[sink].in_port
                    assert !trsc[source].out_port.connected_to?(trsc[sink].in_port)
                    assert source.out_port.connected_to?(sink.in_port)
                    trsc.commit_transaction
                end
                assert !source.out_port.connected_to?(sink.in_port)
            end
        end
    end
end

describe Syskit do

    describe ".resolve_connections" do
        it "should match ports by name" do
            ports = [['port1', '/type1'], ['port2', '/type2']]
            out_ports = ports.map { |n, t| flexmock(name: n, type: t) }
            in_ports  = ports.map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[0]], [out_ports[1], in_ports[1]]].to_set,
                Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should match ports by type" do
            out_ports = [['port1', '/type1'], ['port2', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }
            in_ports = [['port1', '/type2'], ['port2', '/type1']].
                map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[1]], [out_ports[1], in_ports[0]]].to_set,
                Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should raise AmbiguousAutoConnection if a port-by-type match resolves to multiple inputs" do
            out_ports = [['port1', '/type1'], ['port2', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }
            in_ports = [['in_port1', '/type1'], ['in_port2', '/type1']].
                map { |n, t| flexmock(name: n, type: t) }

            assert_raises(Syskit::AmbiguousAutoConnection) do
                Syskit.resolve_connections(out_ports, in_ports)
            end
        end
        it "should take into account exact matches to resolve ambiguous port-by-type matches" do
            # Important: the exact name match should be second so that we are
            # sure that it is not a fluke due to the order
            out_ports = [['port1', '/type2'], ['port2', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }
            in_ports = [['port1', '/type2'], ['port2', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }

            assert_equal [[out_ports[0], in_ports[0]], [out_ports[1], in_ports[1]]].to_set,
                Syskit.resolve_connections(out_ports, in_ports).to_set
        end
        it "should raise AmbiguousAutoConnection if more than one output gets connected to a non-multiplexing input" do
            out_ports = [['port1', '/type2'], ['port1', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }
            in_ports = [flexmock(name: 'port', type: '/type2', :multiplexes? => false)]

            assert_raises(Syskit::AmbiguousAutoConnection) do
                Syskit.resolve_connections(out_ports, in_ports)
            end
        end
        it "should not raise AmbiguousAutoConnection if more than one output gets connected to a multiplexing input" do
            out_ports = [['port1', '/type2'], ['port2', '/type2']].
                map { |n, t| flexmock(name: n, type: t) }
            in_ports = [flexmock(name: 'port', type: '/type2', :multiplexes? => true)]

            Syskit.resolve_connections(out_ports, in_ports)
        end
    end
    describe ".connect" do
        it "should apply the connections as returned by resolve_connections" do
            policy, out_port, in_port = Hash.new, flexmock, flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to).with(in_port, policy).once
            Syskit.connect(out_port, in_port, policy)
        end
        it "should return the list of created connections" do
            policy, out_port, in_port = Hash.new, flexmock, flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            assert_equal [[out_port, in_port]], Syskit.connect(out_port, in_port, policy)
        end
        it "should raise InvalidAutoConnection if no matches are found" do
            policy, out_port, in_port = Hash.new, flexmock, flexmock
            flexmock(Syskit).should_receive(:resolve_connections).and_return([])
            out_port.should_receive(:connect_to).never
            assert_raises(Syskit::InvalidAutoConnection) { Syskit.connect(out_port, in_port, policy) }
        end
        it "should be able to handle a single port as source" do
            policy, out_port, in_port = Hash.new, flexmock, flexmock
            flexmock(Syskit).should_receive(:resolve_connections).with([out_port], any).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, in_port, policy)
        end
        it "should be able to handle a component as source" do
            policy, out_port, in_port, source = Hash.new, flexmock, flexmock, flexmock
            source.should_receive(:each_output_port).and_return(out_port_list = Array.new)
            flexmock(Syskit).should_receive(:resolve_connections).with(out_port_list, [in_port]).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(source, in_port, policy)
        end
        it "should be able to handle a single port as sink" do
            policy, out_port, in_port = Hash.new, flexmock, flexmock
            flexmock(Syskit).should_receive(:resolve_connections).with(any, [in_port]).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, in_port, policy)
        end
        it "should be able to handle a component as sink" do
            policy, out_port, in_port, sink = Hash.new, flexmock, flexmock, flexmock
            sink.should_receive(:each_input_port).and_return(in_port_list = Array.new)
            flexmock(Syskit).should_receive(:resolve_connections).with([out_port], in_port_list).and_return([[out_port, in_port]])
            out_port.should_receive(:connect_to)
            Syskit.connect(out_port, sink, policy)
        end
    end
end
