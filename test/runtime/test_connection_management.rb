# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Runtime
        module ConnectionExecutionSharedTest
            attr_reader :source, :sink, :source_task, :sink_task

            def test_it_creates_a_new_connection_when_a_new_edge_is_added_between_tasks
                mock_raw_port(source_task, "out1").should_receive(:connect_to)
                                                  .with(mock_raw_port(sink_task, "in1"), Hash).once
                                                  .pass_thru
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
            end

            def test_it_passes_the_policy_and_distance_between_the_two_tasks_to_the_underlying_connect_to_call
                policy = Hash[type: :buffer, size: 20]
                flexmock(source.out1_port.to_actual_port.component).should_receive(:distance_to)
                                                                   .with(sink.in1_port.to_actual_port.component)
                                                                   .and_return(distance = flexmock)
                mock_raw_port(source_task, "out1").should_receive(:connect_to)
                                                  .with(mock_raw_port(sink_task, "in1"), distance: distance, **policy).once
                                                  .pass_thru
                source.out1_port.connect_to sink.in1_port, policy
                ConnectionManagement.update(plan)
            end

            def test_it_creates_a_new_connection_when_an_existing_edge_is_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
                source.out2_port.connect_to sink.in2_port
                mock_raw_port(source_task, "out2").should_receive(:connect_to)
                                                  .with(mock_raw_port(sink_task, "in2"), Hash).once
                                                  .pass_thru
                ConnectionManagement.update(plan)
            end

            def test_it_removes_a_new_connection_when_an_existing_edge_is_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                source.out2_port.connect_to sink.in2_port
                ConnectionManagement.update(plan)
                mock_raw_port(source_task, "out2").should_receive(:disconnect_from)
                                                  .with(mock_raw_port(sink_task, "in2")).once
                                                  .pass_thru
                source.out2_port.disconnect_from sink.in2_port
                ConnectionManagement.update(plan)
            end

            def test_it_removes_connections_when_edges_are_removed_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
                source.remove_sink sink
                mock_raw_port(source_task, "out1").should_receive(:disconnect_from)
                                                  .with(mock_raw_port(sink_task, "in1")).once
                                                  .pass_thru
                ConnectionManagement.update(plan)
            end
        end

        describe ConnectionManagement do
            let(:dataflow_graph) { plan.task_relation_graph_for(Flows::DataFlow) }
            before do
                unplug_connection_management
            end

            # Helper method that mocks a port accessed through
            # Orocos::TaskContext#raw_port
            def mock_raw_port(task, port_name)
                if task.respond_to?(:orocos_task)
                    task = task.orocos_task
                end

                port = Orocos.allow_blocking_calls do
                    task.raw_port(port_name)
                end
                flexmock(task).should_receive(:raw_port).with(port_name).and_return(port)
                flexmock(port)
            end

            describe "#update_required_dataflow_graph" do
                before do
                    flexmock(RequiredDataFlow)

                    @source_task = flexmock("source")
                    @task = flexmock("task")
                    @target_task = flexmock("target")
                end

                it "registers all concrete input and output connections of the given tasks" do
                    @task.should_receive(:each_concrete_input_connection)
                         .and_yield(@source_task, "source_port", "sink_port", :inputs)
                    @task.should_receive(:each_concrete_output_connection)
                         .and_yield("source_port", "sink_port", @target_task, :outputs)
                    RequiredDataFlow
                        .should_receive(:add_connections).once
                        .with(@source_task, @task, %w[source_port sink_port] => :inputs)
                    RequiredDataFlow
                        .should_receive(:add_connections).once
                        .with(@task, @target_task, %w[source_port sink_port] => :outputs)
                    ConnectionManagement.new(plan).update_required_dataflow_graph([@task])
                end

                it "primarily uses information stored in the policy grap to determine the policies" do
                    @task.should_receive(:each_concrete_input_connection)
                         .and_yield(@source_task, "source_port", "sink_port", :inputs)
                    @task.should_receive(:each_concrete_output_connection)
                         .and_yield("source_port", "sink_port", @target_task, :outputs)
                    RequiredDataFlow
                        .should_receive(:add_connections).once
                        .with(@source_task, @task,
                              %w[source_port sink_port] => :policy_g_input)
                    RequiredDataFlow
                        .should_receive(:add_connections).once
                        .with(@task, @target_task,
                              %w[source_port sink_port] => :policy_g_output)

                    dataflow_g = plan.task_relation_graph_for(Flows::DataFlow)
                    dataflow_g.policy_graph.merge!(
                        [@source_task, @task] => {
                            %w[source_port sink_port] => :policy_g_input
                        },
                        [@task, @target_task] => {
                            %w[source_port sink_port] => :policy_g_output
                        }
                    )
                    ConnectionManagement.new(plan).update_required_dataflow_graph([@task])
                end

                it "does not add the same connection twice" do
                    @task.should_receive(:each_concrete_input_connection)
                         .and_yield(@source_task, "source_port", "sink_port", :inputs)
                    @task.should_receive(:each_concrete_output_connection)
                    @source_task.should_receive(:each_concrete_output_connection)
                                .and_yield("source_port", "sink_port", @task, :inputs)
                    @source_task.should_receive(:each_concrete_input_connection)
                    flexmock(RequiredDataFlow)
                        .should_receive(:add_connections).once
                        .with(@source_task, @task, %w[source_port sink_port] => :inputs)
                    ConnectionManagement
                        .new(plan)
                        .update_required_dataflow_graph([@task, @source_task])
                end
            end

            describe "#removed_connections_require_network_update?" do
                let(:management) { ConnectionManagement.new(plan) }
                attr_reader :source_task, :sink_task
                before do
                    @source_task = syskit_stub_and_deploy("source") do
                        output_port "out", "/double"
                    end
                    @sink_task = syskit_stub_and_deploy("sink") do
                        input_port "in", "/double"
                    end
                    syskit_start_execution_agents(source_task)
                    syskit_start_execution_agents(sink_task)
                end

                it "returns false if the ports are not static" do
                    flexmock(ActualDataFlow, :static? => false)
                    assert !management.removed_connections_require_network_update?(
                        Hash[[source_task, sink_task] => %w[out in]]
                    )
                end

                describe "static source port" do
                    before do
                        flexmock(ActualDataFlow).should_receive(:static?)
                                                .with(source_task.orocos_task, "out").and_return(true)
                        flexmock(ActualDataFlow).should_receive(:static?)
                                                .with(sink_task.orocos_task, "in").and_return(false)
                    end

                    it "returns false if the modified task is not represented in the plan" do
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                    it "returns false if the modified task is to be garbage-collected" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task)
                                            .and_return(source_task)
                        plan.unmark_mission_task(source_task)
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                    it "returns true if the task is already configured" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task)
                                            .and_return(source_task)
                        assert management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                end

                describe "static sink port" do
                    before do
                        flexmock(ActualDataFlow).should_receive(:static?)
                                                .with(source_task.orocos_task, "out").and_return(false)
                        flexmock(ActualDataFlow).should_receive(:static?)
                                                .with(sink_task.orocos_task, "in").and_return(true)
                    end

                    it "returns false if the modified task is not represented in the plan" do
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                    it "returns false if the modified task is to be garbage-collected" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task)
                                            .and_return(sink_task)
                        plan.unmark_mission_task(sink_task)
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                    it "returns true if the task is already configured" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task)
                                            .and_return(sink_task)
                        assert management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [%w[out in]]]
                        )
                    end
                end
            end

            describe "#update" do
                describe "interaction between connections and task states" do
                    attr_reader :source_task, :sink_task
                    before do
                        @source_task = syskit_stub_and_deploy("source") do
                            output_port "out", "/double"
                        end
                        @sink_task = syskit_stub_and_deploy("sink") do
                            input_port "in", "/double"
                        end
                        syskit_start_execution_agents(source_task)
                        syskit_start_execution_agents(sink_task)
                        @source_deployment = source_task.execution_agent
                        @sink_deployment   = sink_task.execution_agent
                    end

                    it "connects input static ports before the task gets set up" do
                        out_port = mock_raw_port(source_task, "out")
                        in_port  = mock_raw_port(sink_task, "in")
                        out_port.should_receive(:connect_to)
                                .with(in_port, Hash).once.pass_thru

                        flexmock(sink_task.orocos_task).should_receive(:configure)
                                                       .once.ordered.pass_thru
                        source_task.connect_to(sink_task)
                        refute sink_task.ready_for_setup?,
                               "#{sink_task} is ready_for_setup? but its inputs are "\
                               "not connected yet"
                        ConnectionManagement.update(plan)
                        assert sink_task.ready_for_setup?
                        expect_execution.scheduler(true).to { emit sink_task.start_event }
                    end

                    describe "handling of static ports" do
                        it "triggers a redeployment if "\
                            "#removed_connections_require_network_update? returns true" do
                            expected = dataflow_graph.pending_changes =
                                [Set.new, flexmock(:base, {}, empty?: false),
                                 flexmock(:base, {}, empty?: false)]

                            flexmock(manager = ConnectionManagement.new(plan))
                            manager.should_receive(:removed_connections_require_network_update?)
                                   .and_return(true)
                            manager.should_receive(:update).once.pass_thru.ordered
                            flexmock(Runtime).should_receive(:apply_requirement_modifications)
                                             .with(any, force: true).once.ordered
                            manager.update
                            assert_equal expected, dataflow_graph.pending_changes
                            dataflow_graph.pending_changes = nil
                        end

                        describe "stopped tasks" do
                            def self.common
                                it "disconnects a static source port and marks the task for reconfiguration" do
                                    prepare(true, false)
                                    assert @source_deployment
                                        .needs_reconfiguration?(source_task.orocos_name)
                                    refute @sink_deployment
                                        .needs_reconfiguration?(sink_task.orocos_name)
                                end

                                it "disconnects a static sink port and marks the task for reconfiguration" do
                                    prepare(false, true)
                                    ConnectionManagement.update(plan)
                                    refute @source_deployment
                                        .needs_reconfiguration?(source_task.orocos_name)
                                    assert @sink_deployment
                                        .needs_reconfiguration?(sink_task.orocos_name)
                                end
                            end

                            def prepare(source_static, sink_static)
                                mock_raw_port(source_task, "out")
                                    .should_receive(:disconnect_from)
                                    .once.pass_thru
                                Orocos.allow_blocking_calls do
                                    source_task.orocos_task.out.connect_to sink_task.orocos_task.in
                                end
                                ActualDataFlow.add_connections(
                                    source_task.orocos_task,
                                    sink_task.orocos_task,
                                    %w[out in] => [{}, source_static, sink_static]
                                )
                            end

                            describe "orocos tasks with non-static half without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    super
                                    execute do
                                        if source_static
                                            plan.remove_task(sink_task)
                                        else
                                            plan.remove_task(source_task)
                                        end
                                    end
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end

                            describe "orocos tasks with static half without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    super
                                    execute do
                                        if source_static
                                            plan.remove_task(source_task)
                                        else
                                            plan.remove_task(sink_task)
                                        end
                                    end
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end

                            describe "orocos tasks without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    super
                                    execute do
                                        plan.remove_task(source_task)
                                        plan.remove_task(sink_task)
                                    end
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end
                        end
                    end

                    describe "handling of dynamic ports" do
                        it "waits for the tasks to be set up to connect dynamic ports" do
                            source_task.specialize
                            def source_task.configure
                                orocos_task.local_ruby_task.create_output_port "out2", "/double"
                            end
                            source_task.model.orogen_model.output_port "out2", "/double"
                            source_task.out2_port.connect_to sink_task.in_port
                            flexmock(source_task.orocos_task)
                                .should_receive(:configure)
                                .once.globally.ordered
                                .pass_thru
                                .and_return do
                                    mock_raw_port(source_task, "out2")
                                        .should_receive(:connect_to)
                                        .with(mock_raw_port(sink_task, "in"))
                                        .once.globally.ordered
                                    true
                                end
                            expect_execution.scheduler(true).to { emit source_task.start_event }
                        end

                        it "does not connect ports between two running tasks until the rest of the network is ready" do
                            syskit_configure_and_start(source_task)
                            syskit_configure_and_start(sink_task)
                            pre_operational_task = syskit_stub_and_deploy("pre_operational") do
                                input_port "in", "/double"
                            end
                            pre_operational_task.specialize
                            def pre_operational_task.configure
                                orocos_task.local_ruby_task.create_input_port "in2", "/double"
                            end
                            pre_operational_task.model.orogen_model.input_port "in2", "/double"
                            syskit_start_execution_agents(pre_operational_task)

                            source_task.out_port.connect_to sink_task.in_port
                            source_task.out_port.connect_to pre_operational_task.in2_port
                            plug_connection_management

                            flexmock(pre_operational_task.orocos_task)
                                .should_receive(:configure)
                                .once.globally.ordered
                                .pass_thru

                            out_port = mock_raw_port(source_task, "out")
                            in_port  = mock_raw_port(sink_task, "in")
                            out_port.should_receive(:connect_to)
                                    .with(in_port, Hash)
                                    .once.globally.ordered(:connections)
                                    .pass_thru
                            out_port.should_receive(:connect_to)
                                    .with(->(port) { port.name == "in2" }, any)
                                    .once.globally.ordered(:connections)
                                    .pass_thru

                            expect_execution.scheduler(true).to { emit pre_operational_task.start_event }
                        end
                    end

                    describe "policy update of existing connections" do
                        # These check a situation where the deployer would have spawned
                        # a new task (for reconfiguration) that would have a different
                        # policy than the existing policy. It might happen that the Roby
                        # GC would not have removed the old task and the connection
                        # management would create the new connection

                        describe "source tasks" do
                            before do
                                source_task.out_port.connect_to sink_task.in_port,
                                                                type: :buffer
                                ConnectionManagement.update(plan)
                                edge_info = ActualDataFlow.edge_info(
                                    source_task.orocos_task, sink_task.orocos_task
                                )
                                assert_equal Hash[%w[out in] => Hash[type: :buffer]],
                                             edge_info
                            end

                            it "handles an old task still present in the plan while the "\
                                "new task's connection is added, both tasks not setup" do
                                plan.unmark_mission_task(source_task)
                                plan.add(new_source_task = source_task
                                    .execution_agent.task(source_task.orocos_name))
                                new_source_task.out_port
                                               .connect_to sink_task.in_port, type: :data
                                ConnectionManagement.update(plan)
                                assert source_task.out_port.connected_to?(sink_task.in_port)
                                edge_info = ActualDataFlow.edge_info(
                                    new_source_task.orocos_task, sink_task.orocos_task
                                )
                                assert_equal Hash[%w[out in] => Hash[type: :data]],
                                             edge_info
                            end

                            it "handles an old task still present in the plan while "\
                                "the new task's connection is added, the old task "\
                                "being running" do
                                syskit_configure_and_start(source_task)
                                plan.unmark_mission_task(source_task)
                                plan.add_mission_task(new_source_task = source_task
                                    .execution_agent.task(source_task.orocos_name))
                                new_source_task.conf = ["default"]
                                new_source_task.should_configure_after(
                                    source_task.stop_event
                                )
                                new_source_task.out_port.connect_to \
                                    sink_task.in_port, type: :data

                                out_port = mock_raw_port(source_task, "out")
                                in_port  = mock_raw_port(sink_task, "in")
                                new_out_port = mock_raw_port(new_source_task, "out")
                                out_port.should_receive(:disconnect_from)
                                        .with(in_port)
                                        .once.globally.ordered
                                        .pass_thru
                                new_out_port.should_receive(:connect_to)
                                            .with(in_port, Hash)
                                            .once.globally.ordered
                                            .pass_thru
                                ConnectionManagement.update(plan)
                                expect_execution.garbage_collect(true).scheduler(true)
                                                .to { emit new_source_task.start_event }

                                edge_info = ActualDataFlow.edge_info(
                                    new_source_task.orocos_task, sink_task.orocos_task
                                )
                                assert_equal Hash[%w[out in] => Hash[type: :data]],
                                             edge_info
                            end
                        end

                        describe "sink tasks" do
                            before do
                                source_task.out_port
                                           .connect_to sink_task.in_port, type: :buffer
                                ConnectionManagement.update(plan)
                                edge_info = ActualDataFlow.edge_info(
                                    source_task.orocos_task, sink_task.orocos_task
                                )
                                assert_equal Hash[%w[out in] => Hash[type: :buffer]],
                                             edge_info
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, both tasks not setup" do
                                plan.unmark_mission_task(sink_task)
                                plan.add(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                                source_task.out_port.connect_to new_sink_task.in_port, type: :data
                                ConnectionManagement.update(plan)
                                assert source_task.out_port.connected_to?(sink_task.in_port)
                                assert_equal Hash[%w[out in] => Hash[type: :data]], ActualDataFlow.edge_info(source_task.orocos_task, new_sink_task.orocos_task)
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, the old task being running" do
                                syskit_configure_and_start(sink_task)
                                plan.unmark_mission_task(sink_task)
                                plan.add_mission_task(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                                new_sink_task.conf = ["default"]
                                new_sink_task.should_configure_after(sink_task.stop_event)
                                source_task.out_port.connect_to new_sink_task.in_port, type: :data

                                out_port = mock_raw_port(source_task, "out")
                                in_port  = mock_raw_port(sink_task, "in")
                                new_in_port = mock_raw_port(new_sink_task, "in")
                                out_port.should_receive(:disconnect_from)
                                        .with(in_port)
                                        .once.globally.ordered
                                        .pass_thru
                                out_port.should_receive(:connect_to)
                                        .with(new_in_port, Hash[distance: TaskContext::D_SAME_PROCESS, type: :data])
                                        .once.globally.ordered
                                        .pass_thru
                                ConnectionManagement.update(plan)
                                expect_execution.garbage_collect(true).scheduler(true).to { emit new_sink_task.start_event }
                                assert_equal Hash[%w[out in] => Hash[type: :data]], ActualDataFlow.edge_info(source_task.orocos_task, new_sink_task.orocos_task)
                            end
                        end
                    end
                end

                it "triggers a deployment if a connection to a static port is removed "\
                    "on an already setup task" do
                    task_m = TaskContext.new_submodel do
                        input_port("in", "/double").static
                        output_port "out", "/double"
                    end
                    source_m = syskit_stub_requirements(task_m.with_conf("source"))
                    sink_m   = syskit_stub_requirements(task_m.with_conf("sink"))
                    source = syskit_deploy(source_m)
                    sink   = syskit_deploy(sink_m)
                    source.out_port.connect_to sink.in_port
                    syskit_configure_and_start(source)
                    syskit_configure_and_start(sink)
                    source.out_port.disconnect_from sink.in_port

                    sink_srv = sink.as_service
                    ConnectionManagement.update(plan)
                    plan.syskit_join_current_resolution
                    ConnectionManagement.update(plan)
                    refute_equal sink, sink_srv.to_task
                end

                it "detects and applies removed connections between ports, "\
                    "even if the two underlying tasks still have connections" do
                    source_task = syskit_stub_deploy_and_configure("source") do
                        output_port "out1", "/double"
                        output_port "out2", "/double"
                    end
                    sink_task = syskit_stub_deploy_and_configure("sink") do
                        input_port "in1", "/double"
                        input_port "in2", "/double"
                    end
                    source_task.out1_port.connect_to sink_task.in1_port
                    source_task.out2_port.connect_to sink_task.in2_port
                    ConnectionManagement.update(plan)
                    Orocos.allow_blocking_calls do
                        assert source_task.orocos_task.out1.connected?
                        assert source_task.orocos_task.out2.connected?
                    end

                    source_task.out2_port.disconnect_from sink_task.in2_port
                    ConnectionManagement.update(plan)
                    Orocos.allow_blocking_calls do
                        assert source_task.orocos_task.out1.connected?
                        assert !source_task.orocos_task.out2.connected?
                    end
                end

                it "carries the tasks over to the next cycle for pending connections" do
                    source_task = syskit_stub_deploy_and_configure("source")
                    sink_task = syskit_stub_deploy_and_configure("sink")

                    manager = ConnectionManagement.new(plan)
                    flexmock(manager).should_receive(:compute_connection_changes)
                                     .with(Set[source_task]).once.ordered
                                     .and_return([{}, {}])
                    flexmock(manager).should_receive(:compute_connection_changes)
                                     .with(Set[source_task, sink_task]).once.ordered
                                     .and_return([{}, {}])
                    flexmock(manager).should_receive(:apply_connection_changes)
                                     .and_return([
                                                     flexmock(:base, {}, empty?: false),
                                                     flexmock(:base, {}, empty?: false)
                                                 ])
                    dataflow_graph = plan.task_relation_graph_for(Syskit::Flows::DataFlow)
                    dataflow_graph.modified_tasks << source_task

                    manager.update
                    dataflow_graph.modified_tasks << sink_task
                    manager.update
                end

                describe "handling of reconfigured tasks" do
                    before do
                        @source_m = Syskit::TaskContext.new_submodel do
                            output_port "out", "/double"
                        end
                        @sink_m = Syskit::TaskContext.new_submodel do
                            input_port "in", "/double"
                        end
                        @cmp_m = Syskit::Composition.new_submodel
                        @cmp_m.add @source_m, as: "source"
                        @cmp_m.add @sink_m, as: "sink"
                        @cmp_m.source_child.out_port.connect_to \
                            @cmp_m.sink_child.in_port

                        @cmp = syskit_stub_deploy_and_configure(@cmp_m)
                        @source_old = @cmp.source_child
                        @sink       = @cmp.sink_child
                    end

                    def create_new_source
                        agent = @source_old.execution_agent
                        name  = @source_old.orocos_name
                        plan.add_permanent_task(source_new = agent.task(name))
                        source_new.should_configure_after(@source_old.stop_event)
                        syskit_stub_and_deploy(
                            @cmp_m.use(
                                "source" => source_new,
                                "sink" => @sink
                            )
                        )
                        plan.unmark_mission_task(@cmp)
                        source_new
                    end

                    it "handles the old task being finalized" do
                        source_new = create_new_source
                        source_old = @source_old
                        expect_execution.garbage_collect(true).to do
                            finalize source_old
                        end

                        execute { ConnectionManagement.update(plan) }
                        assert(Orocos.allow_blocking_calls do
                            source_new.out_port.to_orocos_port.connected?
                        end)
                    end

                    it "handles a sequential add/finalize" do
                        source_new = create_new_source
                        source_old = @source_old
                        expect_execution { ConnectionManagement.update(plan) }
                            .to_run
                        assert source_old.plan

                        execute do
                            plan.execution_engine.garbage_collect([source_old])
                            ConnectionManagement.update(plan)
                        end
                        assert(Orocos.allow_blocking_calls do
                            source_new.out_port.to_orocos_port.connected?
                        end)
                    end

                    it "handles the old task being disconnected but not finalized" do
                        source_new = create_new_source
                        source_old = @source_old
                        execute do
                            source_old.out_port.disconnect_from @sink.in_port
                            ConnectionManagement.update(plan)
                        end
                        assert(Orocos.allow_blocking_calls do
                            source_new.out_port.to_orocos_port.connected?
                        end)
                    end

                    it "handles a sequential add/disconnect" do
                        source_new = create_new_source
                        source_old = @source_old
                        expect_execution { ConnectionManagement.update(plan) }
                            .to_run
                        assert source_old.plan

                        execute do
                            source_old.out_port.disconnect_from @sink.in_port
                            ConnectionManagement.update(plan)
                        end
                        assert(Orocos.allow_blocking_calls do
                            source_new.out_port.to_orocos_port.connected?
                        end)
                    end
                end
            end

            describe "connections involving finalized task" do
                attr_reader :source, :sink, :task_m
                attr_reader :source_orocos_task, :sink_orocos_task
                before do
                    unplug_connection_management
                    @task_m = TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @source = syskit_stub_deploy_and_configure(task_m.with_conf("test0"))
                    @sink   = syskit_stub_deploy_and_configure(task_m.with_conf("test1"))
                    plan.add_permanent_task(source.execution_agent)
                    plan.add_permanent_task(sink.execution_agent)
                    @source_orocos_task = source.orocos_task
                    @sink_orocos_task = sink.orocos_task
                    syskit_start(sink)
                    syskit_start(source)
                    source.out_port.connect_to sink.in_port
                    ConnectionManagement.update(plan)
                    assert dataflow_graph.modified_tasks.empty?
                end

                def assert_is_disconnected(source_alive: true, sink_alive: true)
                    assert ActualDataFlow.edges.empty?
                    if source_alive
                        Orocos.allow_blocking_calls do
                            assert !source_orocos_task.out.connected?
                        end
                    end
                    if sink_alive
                        Orocos.allow_blocking_calls do
                            assert !sink_orocos_task.in.connected?
                        end
                    end
                end

                it "removes a connection from a non-finalized task and a finalized one" do
                    stop_and_collect_tasks sink
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "removes a connection from a finalized task to a non-finalized one" do
                    stop_and_collect_tasks source
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "removes dangling connections between tasks that have been finalized" do
                    stop_and_collect_tasks(source, sink)
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "removes connections when the source deployment is stopped" do
                    stop_and_collect_execution_agents(source)
                    flexmock(ConnectionManagement).new_instances.should_receive(:warn)
                                                  .with(/error while disconnecting|I am assuming that the disconnection is actually effective/)
                    ConnectionManagement.update(plan)
                    assert_is_disconnected(source_alive: false)
                end

                it "removes connections when the sink deployment is stopped" do
                    stop_and_collect_execution_agents(sink)
                    flexmock(ConnectionManagement).new_instances.should_receive(:warn)
                                                  .with(/error while disconnecting|I am assuming that the disconnection is actually effective/)
                    ConnectionManagement.update(plan)
                    assert_is_disconnected(sink_alive: false)
                end
            end

            it "raises if an expected input port is not present on a configured task" do
                source_m  = TaskContext.new_submodel { output_port("out", "/double") }
                sink_m    = TaskContext.new_submodel
                source = syskit_stub_deploy_and_configure(source_m)
                sink   = syskit_stub_deploy_and_configure(sink_m)
                sink.specialize
                sink.model.orogen_model.input_port "in", "/double"
                source.out_port.connect_to sink.in_port
                exception = expect_execution { ConnectionManagement.update(plan) }
                            .to { have_error_matching PortNotFound.match.with_origin(sink) }
                            .exception
                assert_equal "in", exception.port_name
                assert_equal :input, exception.port_kind
            end
            it "raises if an expected output port is not present on a configured task" do
                source_m  = TaskContext.new_submodel
                sink_m    = TaskContext.new_submodel { input_port("in", "/double") }
                source = syskit_stub_deploy_and_configure(source_m)
                sink   = syskit_stub_deploy_and_configure(sink_m)
                source.specialize
                source.model.orogen_model.output_port "out", "/double"
                source.out_port.connect_to sink.in_port
                exception = expect_execution { ConnectionManagement.update(plan) }
                            .to { have_error_matching PortNotFound.match.with_origin(source) }
                            .exception
                assert_equal "out", exception.port_name
                assert_equal :output, exception.port_kind
            end

            describe "#partition_early_late" do
                attr_reader :manager, :connections, :source, :sink
                before do
                    @manager = ConnectionManagement.new(plan)
                    @source = flexmock
                    @sink = flexmock
                    @connections = Hash[[source, sink] => {}]
                end

                def make_syskit_task_map(source_state, sink_state)
                    source_state = unless source_state.nil?
                                       flexmock(running?: source_state)
                                   end
                    sink_state = unless sink_state.nil?
                                     flexmock(running?: sink_state)
                                 end
                    map = flexmock
                    map.should_receive(:[]).with(source).and_return(source_state)
                    map.should_receive(:[]).with(sink).and_return(sink_state)
                    map
                end

                it "returns a hash for the late connections" do
                    # The return type of early is really #each, but for 'late'
                    # we need a map
                    _, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(true, true)
                    )
                    assert_kind_of Hash, late
                end

                it "interprets the absence of a syskit task for the source as stopped" do
                    early, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(nil, true)
                    )
                    assert_equal connections.to_a, early
                    assert_equal({}, late)
                end

                it "interprets the absence of a syskit task for the sink as stopped" do
                    early, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(true, nil)
                    )
                    assert_equal connections.to_a, early
                    assert_equal({}, late)
                end

                it "places in early connections involving a non-running source" do
                    early, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(false, true)
                    )
                    assert_equal connections.to_a, early
                    assert_equal({}, late)
                end

                it "places in early connections involving a non-running sink" do
                    early, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(true, false)
                    )
                    assert_equal connections.to_a, early
                    assert_equal({}, late)
                end

                it "places in late connections involving running source and sink" do
                    early, late = manager.partition_early_late(
                        connections, "", make_syskit_task_map(true, true)
                    )
                    assert_equal [], early
                    assert_equal connections, late
                end
            end

            describe "the basic behaviour" do
                it "waits for the tasks to be deployed before creating new connections" do
                    source_m = TaskContext.new_submodel do
                        output_port "out", "/double"
                    end
                    sink_m = TaskContext.new_submodel do
                        input_port "in", "/double"
                    end
                    source = syskit_stub_and_deploy(source_m)
                    sink   = syskit_stub_and_deploy(sink_m)
                    source.out_port.connect_to sink.in_port
                    assert(!source.execution_agent.running? && !sink.execution_agent.running?)
                    ConnectionManagement.update(plan)
                    syskit_start_execution_agents(source)
                    ConnectionManagement.update(plan)
                    assert(!sink.execution_agent.running?)
                    syskit_start_execution_agents(sink)
                    mock_raw_port(source, "out").should_receive(:connect_to)
                                                .with(mock_raw_port(sink, "in"), Hash).once
                                                .pass_thru
                    ConnectionManagement.update(plan)
                end

                describe "between task contexts" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port "in1", "/double"
                            input_port "in2", "/double"
                        end
                        @source = syskit_stub_and_deploy(source_m)
                        syskit_start_execution_agents(source)
                        @source_task = source.orocos_task
                        @sink = syskit_stub_and_deploy(sink_m)
                        syskit_start_execution_agents(sink)
                        @sink_task = sink.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end

                describe "between a composition and a task" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        cmp_m = Composition.new_submodel do
                            add source_m, as: "test"
                            export test_child.out1_port
                            export test_child.out2_port
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port "in1", "/double"
                            input_port "in2", "/double"
                        end
                        @source = syskit_stub_and_deploy(cmp_m)
                        syskit_start_execution_agents(source)
                        @source_task = source.test_child.orocos_task
                        @sink = syskit_stub_and_deploy(sink_m)
                        syskit_start_execution_agents(sink)
                        @sink_task = sink.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end

                describe "between a task and a composition" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port "in1", "/double"
                            input_port "in2", "/double"
                        end
                        cmp_m = Composition.new_submodel do
                            add sink_m, as: "test"
                            export test_child.in1_port
                            export test_child.in2_port
                        end
                        @source = syskit_stub_and_deploy(source_m)
                        syskit_start_execution_agents(source)
                        @source_task = source.orocos_task
                        @sink = syskit_stub_and_deploy(cmp_m)
                        syskit_start_execution_agents(sink)
                        @sink_task = sink.test_child.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end

                describe "between two compositions" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        source_cmp_m = Composition.new_submodel do
                            add source_m, as: "test"
                            export test_child.out1_port
                            export test_child.out2_port
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port "in1", "/double"
                            input_port "in2", "/double"
                        end
                        sink_cmp_m = Composition.new_submodel do
                            add sink_m, as: "test"
                            export test_child.in1_port
                            export test_child.in2_port
                        end
                        @source = syskit_stub_and_deploy(source_cmp_m)
                        syskit_start_execution_agents(source.test_child)
                        @source_task = source.test_child.orocos_task
                        @sink = syskit_stub_and_deploy(sink_cmp_m)
                        syskit_start_execution_agents(sink.test_child)
                        @sink_task = sink.test_child.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end
            end

            describe "handling of dead deployments" do
                attr_reader :source_task, :sink_task, :source_agent, :sink_agent, :source_orocos, :sink_orocos
                before do
                    unplug_connection_management
                    task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @source_task = syskit_stub_deploy_configure_and_start(task_m.with_conf("source_task"))
                    @sink_task = syskit_stub_deploy_configure_and_start(task_m.with_conf("sink_task"))
                    @source_orocos = source_task.orocos_task
                    @sink_orocos = sink_task.orocos_task
                    plan.add_permanent_task(@source_agent = source_task.execution_agent)
                    plan.add_permanent_task(@sink_agent = sink_task.execution_agent)

                    source_task.out_port.connect_to sink_task.in_port
                    Syskit::Runtime::ConnectionManagement.update(plan)
                end

                def assert_disconnection_fails_and_warns(source_orocos_task, source_port, sink_orocos_task, sink_port, reference_match = ".*")
                    first_line  = "error while disconnecting #{source_orocos_task}:#{source_port} => #{sink_orocos_task}:#{sink_port}"
                    second_line = "I am assuming that the disconnection is actually effective, since one port does not exist anymore and\/or the task cannot be contacted \(i\.e\. assumed to be dead)"
                    manager = flexmock(ConnectionManagement).new_instances
                    manager.should_receive(:warn).with(/#{Regexp.quote(first_line)}: #{reference_match}/).once
                    manager.should_receive(:warn).with(second_line).once
                end

                # This is really a system test. We simulate having pending new and
                # removed connections that are queued because some tasks are not set up,
                # and then kill the tasks involved. The resulting operation should work
                # fine (i.e. not creating the dead connections)
                it "handles pending new connections that involve a dead task" do
                    ConnectionManagement.update(plan)
                    stop_and_collect_execution_agents source_task

                    assert_disconnection_fails_and_warns(source_orocos, "out", sink_orocos, "in")
                    ConnectionManagement.update(plan)
                end

                it "handles pending removed connections that involve a dead task" do
                    plan.unmark_mission_task source_task
                    plan.unmark_permanent_task source_agent
                    ConnectionManagement.update(plan)
                    source_task.disconnect_ports(sink_task, [%w[out in]])
                    stop_and_collect_execution_agents source_task
                    assert_disconnection_fails_and_warns(source_orocos, "out", sink_orocos, "in")
                    ConnectionManagement.update(plan)
                end

                describe "connection add/remove hooks" do
                    it "calls them on the remaining sinks" do
                        stop_and_collect_tasks source_task
                        assert Syskit::ActualDataFlow.has_edge?(source_orocos, sink_orocos)
                        flexmock(sink_task).should_receive(:removing_input_port_connection)
                                           .with(source_orocos, "out", "in").once.globally.ordered
                        flexmock(sink_task).should_receive(:removed_input_port_connection)
                                           .with(source_orocos, "out", "in").once.globally.ordered
                        execute { source_agent.stop! }
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end

                    it "calls them on the remaining sources" do
                        stop_and_collect_tasks sink_task
                        assert Syskit::ActualDataFlow.has_edge?(source_orocos, sink_orocos)
                        flexmock(source_task).should_receive(:removing_output_port_connection)
                                             .with("out", sink_orocos, "in").once.globally.ordered
                        flexmock(source_task).should_receive(:removed_output_port_connection)
                                             .with("out", sink_orocos, "in").once.globally.ordered
                        execute { sink_agent.stop! }
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end
                end
            end

            def stop_and_collect_tasks(*tasks)
                expect_execution do
                    tasks.each(&:stop!)
                end.to do
                    tasks.each { |t| emit t.stop_event }
                end
                expect_execution.garbage_collect(true).to_run
            end

            def stop_and_collect_execution_agents(*tasks)
                expect_execution do
                    tasks.each { |t| t.execution_agent.stop! }
                end.to do
                    tasks.each do |t|
                        emit t.execution_agent.stop_event
                        emit t.aborted_event
                    end
                end
                expect_execution.garbage_collect(true).to_run
            end
        end
    end
end
