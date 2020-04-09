# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe DataFlow do
        subject { plan.task_relation_graph_for(Flows::DataFlow) }
        let(:task_m) do
            Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
        end
        let(:cmp_m) do
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "test"
            cmp_m.export cmp_m.test_child.in_port
            cmp_m.export cmp_m.test_child.out_port
            cmp_m
        end

        attr_reader :tasks, :cmp
        before do
            @cmp   = []
            @tasks = []
            4.times do |i|
                cmp[i] = cmp_m.instanciate(plan)
                tasks[i] = cmp[i].test_child
            end
        end

        after do
            if subject.concrete_connection_graph_enabled?
                subject.disable_concrete_connection_graph
            end
        end

        describe "#forward_input_ports" do
            attr_reader :cmp, :task, :dataflow_graph, :plan
            before do
                @plan = Roby::Plan.new
                @dataflow_graph = plan.task_relation_graph_for(Syskit::DataFlow)
                plan.add(@cmp = cmp_m.new)
                plan.add(@task = task_m.new)
                cmp.depends_on task, role: "test"
            end
            it "creates connections between a composition's input port and a task" do
                cmp.forward_input_ports(task, %w[in in] => {})
                assert_equal Hash[%w[in in] => {}],
                             dataflow_graph.edge_info(cmp, task)
            end
            it "raises if the ports are not input ports" do
                assert_raises(DataFlow::Extension::NotInputPort) do
                    cmp.forward_input_ports(task, %w[out in] => {})
                end
                assert_raises(DataFlow::Extension::NotInputPort) do
                    cmp.forward_input_ports(task, %w[in out] => {})
                end
            end
            it "raises if the ports do not exist" do
                assert_raises(DataFlow::Extension::NotInputPort) do
                    cmp.forward_input_ports(task, %w[does_not_exist in] => {})
                end
                assert_raises(DataFlow::Extension::NotInputPort) do
                    cmp.forward_input_ports(task, %w[in does_not_exist] => {})
                end
            end
            it "does not create an edge in the connection graph if the mappings are empty" do
                cmp.forward_input_ports(task, {})
                refute dataflow_graph.has_edge?(cmp, task)
            end
        end

        describe "#forward_output_ports" do
            attr_reader :cmp, :task, :dataflow_graph, :plan
            before do
                @plan = Roby::Plan.new
                @dataflow_graph = plan.task_relation_graph_for(Syskit::DataFlow)
                plan.add(@cmp = cmp_m.new)
                plan.add(@task = task_m.new)
                cmp.depends_on task, role: "test"
            end
            it "creates connections between a composition's output port and a task" do
                task.forward_output_ports(cmp, %w[out out] => {})
                assert_equal Hash[%w[out out] => {}],
                             dataflow_graph.edge_info(task, cmp)
            end
            it "raises if the ports are not output ports" do
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    task.forward_output_ports(cmp, %w[out in] => {})
                end
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    task.forward_output_ports(cmp, %w[in out] => {})
                end
            end
            it "raises if the ports do not exist" do
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    task.forward_output_ports(cmp, %w[does_not_exist out] => {})
                end
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    task.forward_output_ports(cmp, %w[out does_not_exist] => {})
                end
            end
            it "does not create an edge in the connection graph if the mappings are empty" do
                task.forward_output_ports(cmp, {})
                refute dataflow_graph.has_edge?(task, cmp)
            end
        end

        describe "#connect_ports" do
            attr_reader :source, :sink, :dataflow_graph, :plan
            before do
                @plan = Roby::Plan.new
                @dataflow_graph = plan.task_relation_graph_for(Syskit::DataFlow)
                plan.add(@source = task_m.new)
                plan.add(@sink = task_m.new)
            end
            it "registers the connection between the ports" do
                source.connect_ports sink, %w[out in] => {}
                assert_equal Hash[%w[out in] => {}],
                             dataflow_graph.edge_info(source, sink)
            end
            it "raises if the ports have an invalid direction" do
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    source.connect_ports sink, %w[in in] => {}
                end
                assert_raises(DataFlow::Extension::NotInputPort) do
                    source.connect_ports sink, %w[out out] => {}
                end
            end
            it "raises if one of the ports do not exist" do
                assert_raises(DataFlow::Extension::NotOutputPort) do
                    source.connect_ports sink, %w[does_not_exist in] => {}
                end
                assert_raises(DataFlow::Extension::NotInputPort) do
                    source.connect_ports sink, %w[out does_not_exist] => {}
                end
            end
            it "does not add an edge in the graph if the mappings are empty" do
                source.connect_ports sink, {}
                refute dataflow_graph.has_edge?(source, sink)
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
                assert_equal Set[[tasks[1], "out", "in", {}],
                                 [tasks[2], "out", "in", {}],
                                 [tasks[3], "out", "in", {}]],
                             subject.each_concrete_in_connection(tasks[0]).to_set
            end
            it "ignores a connection to a composition whose port is not forwarded" do
                cmp[1].out_port.connect_to tasks[0].in_port
                cmp[1].test_child.remove_sink(cmp[1])
                assert_equal [], subject.each_concrete_in_connection(tasks[0]).to_a
            end
            it "assumes that #concrete_connection_graph is authoritative if enabled" do
                cmp[1].out_port.connect_to   tasks[0].in_port
                tasks[2].out_port.connect_to tasks[0].in_port
                cmp[3].out_port.connect_to   cmp[0].in_port
                subject.enable_concrete_connection_graph
                # Remove one actual concrete connection from the graph, and make
                # sure that #each_concrete_in_connection misses that connection
                subject.concrete_connection_graph.remove_edge(tasks[1], tasks[0])
                assert_equal Set[[tasks[2], "out", "in", {}],
                                 [tasks[3], "out", "in", {}]],
                             subject.each_concrete_in_connection(tasks[0]).to_set
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
                assert_equal Set[["out", "in", tasks[1], {}],
                                 ["out", "in", tasks[2], {}],
                                 ["out", "in", tasks[3], {}]],
                             subject.each_concrete_out_connection(tasks[0]).to_set
            end
            it "ignores a connection to a composition whose port is not forwarded" do
                tasks[0].out_port.connect_to cmp[1].in_port
                cmp[1].remove_sink(cmp[1].test_child)
                assert_equal [], subject.each_concrete_out_connection(tasks[0]).to_a
            end
            it "assumes that #concrete_connection_graph is authoritative if enabled" do
                tasks[0].out_port.connect_to tasks[1].in_port
                tasks[0].out_port.connect_to cmp[2].in_port
                cmp[0].out_port.connect_to   cmp[3].in_port
                subject.enable_concrete_connection_graph
                # Remove one actual concrete connection from the graph, and make
                # sure that #each_concrete_in_connection misses that connection
                subject.concrete_connection_graph.remove_edge(tasks[0], tasks[1])
                assert_equal Set[["out", "in", tasks[2], {}],
                                 ["out", "in", tasks[3], {}]],
                             subject.each_concrete_out_connection(tasks[0]).to_set
            end
        end

        describe "#compute_concrete_connection_graph" do
            it "builds a graph that represents all the concrete connections" do
                dataflow = Flows::DataFlow.new
                dataflow.add_vertex(task = Syskit::TaskContext.new)
                flexmock(dataflow).should_receive(:each_concrete_in_connection)
                                  .and_iterates([source1 = Object.new, "out", "in", {}],
                                                [source2 = Object.new, "out", "in", {}])
                expected = [
                    [source1, task, %w[out in] => {}],
                    [source2, task, %w[out in] => {}]
                ]

                graph = dataflow.compute_concrete_connection_graph
                assert_equal expected.to_set, graph.each_edge.to_set
            end
            it "ignores non-TaskContext vertices" do
                dataflow = Flows::DataFlow.new
                dataflow.add_vertex(task = Syskit::Composition.new)
                flexmock(dataflow).should_receive(:each_concrete_in_connection)
                                  .and_iterates([source1 = Object.new, "out", "in", {}],
                                                [source2 = Object.new, "out", "in", {}])
                graph = dataflow.compute_concrete_connection_graph
                assert graph.each_edge.empty?
            end
        end

        describe DataFlow::ConcreteConnectionGraph do
            it "updates the policy when replacing vertices" do
                concrete_graph = DataFlow::ConcreteConnectionGraph.new
                old_source = Object.new
                new_source = Object.new
                sink = Object.new
                concrete_graph.add_edge(old_source, sink, %w[out in] => {}, %w[other_out in] => {})
                concrete_graph.add_edge(new_source, sink, %w[out in] => Hash[type: :data])
                concrete_graph.replace_vertex(old_source, new_source)
                assert_equal Hash[%w[out in] => Hash[type: :data], %w[other_out in] => {}],
                             concrete_graph.edge_info(new_source, sink)
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
