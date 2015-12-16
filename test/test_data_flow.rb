require 'syskit/test/self'

module Syskit
    describe DataFlow do
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
