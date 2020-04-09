# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe ConnectionGraph do
        subject { ConnectionGraph.new }
        let(:source_m) do
            Syskit::TaskContext.new_submodel do
                output_port "out1", "/double"
                output_port "out2", "/double"
            end
        end
        let(:sink_m) do
            Syskit::TaskContext.new_submodel do
                input_port "in1", "/double"
                input_port "in2", "/double"
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
                    subject.add_edge(source, sink, {})
                end
            end
            it "allows to add new connections to an existing edge" do
                subject.add_edge(source, sink,
                                 %w[out1 in1] => {})
                subject.add_edge(source, sink,
                                 %w[out2 in2] => {})
                assert_equal Hash[%w[out1 in1] => {}, %w[out2 in2] => {}],
                             subject.edge_info(source, sink)
            end
            it "passes if trying to update the policy of a connection with itself" do
                subject.add_edge(source, sink,
                                 %w[out1 in1] => {})
                subject.add_edge(source, sink,
                                 %w[out2 sink2] => {}, %w[out1 in1] => {})
                assert_equal Hash[%w[out1 in1] => {}, %w[out2 sink2] => {}],
                             subject.edge_info(source, sink)
            end
            it "raises if trying to change the policy of an existing connection" do
                subject.add_edge(source, sink,
                                 %w[out1 in1] => {})
                assert_raises(ArgumentError) do
                    subject.add_edge(source, sink,
                                     %w[out1 in1] => Hash[buffer: 10])
                end
                assert_equal Hash[%w[out1 in1] => {}],
                             subject.edge_info(source, sink)
            end
        end

        describe "#has_out_connections?" do
            it "returns false for unconnected tasks" do
                assert !subject.has_out_connections?(source, "out1")
            end
            it "returns false for tasks that have connections, but not of the required out port" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert !subject.has_out_connections?(source, "out2")
            end
            it "returns true for tasks that have connections for the required out port" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert subject.has_out_connections?(source, "out1")
            end
        end

        describe "#has_in_connections?" do
            it "returns false for unconnected tasks" do
                assert !subject.has_in_connections?(sink, "in1")
            end
            it "returns false for tasks that have connections, but not of the required in port" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert !subject.has_in_connections?(sink, "in2")
            end
            it "returns true for tasks that have connections for the required in port" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert subject.has_in_connections?(sink, "in1")
            end
        end

        describe "#connected?" do
            it "returns false for unconnected tasks" do
                assert !subject.connected?(source, "out1", sink, "in1")
            end
            it "returns false for tasks that have connections, but not the required one" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert !subject.connected?(source, "out1", sink, "in2")
            end
            it "returns true for tasks that have connections for the required in port" do
                subject.add_connections(source, sink, %w[out1 in1] => {})
                assert subject.connected?(source, "out1", sink, "in1")
            end
        end

        describe "#each_in_connection" do
            it "yields nothing if there are no input connections" do
                assert subject.each_in_connection(sink).to_a.empty?
            end
            it "enumerates the required connections" do
                subject.add_connections(source, sink,
                                        %w[out1 in1] => {},
                                        %w[out2 in1] => {},
                                        %w[out2 in2] => {})
                assert_equal [[source, "out1", "in1", {}], [source, "out2", "in1", {}], [source, "out2", "in2", {}]],
                             subject.each_in_connection(sink).to_a
            end
            it "restricts itself to the given port" do
                subject.add_connections(source, sink,
                                        %w[out1 in1] => {},
                                        %w[out2 in1] => {},
                                        %w[out2 in2] => {})
                assert_equal [[source, "out2", "in2", {}]],
                             subject.each_in_connection(sink, "in2").to_a
            end
        end

        describe "#each_out_connection" do
            it "yields nothing if there are no output connections" do
                assert subject.each_in_connection(source).to_a.empty?
            end
            it "enumerates the required connections" do
                subject.add_connections(source, sink,
                                        %w[out1 in1] => {},
                                        %w[out2 in1] => {},
                                        %w[out2 in2] => {})
                assert_equal [["out1", "in1", sink, {}], ["out2", "in1", sink, {}], ["out2", "in2", sink, {}]],
                             subject.each_out_connection(source).to_a
            end
            it "restricts itself to the given port" do
                subject.add_connections(source, sink,
                                        %w[out1 in1] => {},
                                        %w[out2 in1] => {},
                                        %w[out2 in2] => {})
                assert_equal [["out2", "in1", sink, {}], ["out2", "in2", sink, {}]],
                             subject.each_out_connection(source, "out2").to_a
            end
        end

        describe "#remove_connections" do
            it "deregisters the requested connections from the current edge info" do
                subject.add_connections(source, sink,
                                        %w[out1 in1] => {},
                                        %w[out2 in1] => {},
                                        %w[out2 in2] => {})
                subject.remove_connections(source, sink, [%w[out2 in1]])
                assert_equal Hash[%w[out1 in1] => {}, %w[out2 in2] => {}],
                             subject.edge_info(source, sink)
            end
            it "removes the edge if the remaining mappings are empty" do
                plan.add(source2 = source_m.new)
                plan.add(sink2 = sink_m.new)
                subject.add_connections(source,  sink,  %w[out1 in1] => {})
                subject.add_connections(source2, sink,  %w[out1 in1] => {})
                subject.add_connections(source,  sink2, %w[out1 in1] => {})
                subject.remove_connections(source, sink, [%w[out1 in1]])
                assert !subject.has_edge?(source, sink)
            end
            it "removes the source if it is ends up being connected to nothing" do
                plan.add(source2 = source_m.new)
                subject.add_connections(source,  sink, %w[out1 in1] => {})
                subject.add_connections(source2, sink, %w[out1 in1] => {})

                subject.remove_connections(source, sink, [%w[out1 in1]])
                assert !subject.has_vertex?(source)
                assert subject.has_vertex?(sink)
            end
            it "removes the sink if it is ends up being connected to nothing" do
                plan.add(sink2 = sink_m.new)
                subject.add_connections(source, sink,  %w[out1 in1] => {})
                subject.add_connections(source, sink2, %w[out1 in1] => {})
                subject.remove_connections(source, sink, [%w[out1 in1]])
                assert subject.has_vertex?(source)
                assert !subject.has_vertex?(sink)
            end
        end
    end
end
