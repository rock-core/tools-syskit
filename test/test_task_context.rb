# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe TaskContext do
        # Helper method that mocks a port accessed through
        # Runkit::TaskContext#raw_port
        def mock_raw_port(task, port_name)
            if task.respond_to?(:orocos_task)
                task = task.orocos_task
            end

            port = Runkit.allow_blocking_calls do
                task.raw_port(port_name)
            end
            task.should_receive(:raw_port).with(port_name).and_return(port)
            flexmock(port)
        end

        describe "#can_merge?" do
            attr_reader :merging_task, :merged_task
            before do
                task_m = TaskContext.new_submodel
                @merging_task = task_m.new
                @merged_task  = task_m.new
            end
            it "returns true for the same tasks" do
                assert merging_task.can_merge?(merged_task)
            end
            it "returns true if only one of the two tasks have a required host" do
                merging_task.required_host = "host"
                assert merging_task.can_merge?(merged_task)
                assert merged_task.can_merge?(merging_task)
            end
            it "returns true if both tasks have a required host and it is identical" do
                merging_task.required_host = "host"
                merged_task.required_host = "host"
                assert merging_task.can_merge?(merged_task)
            end
            it "returns false if both tasks have a required host and it differs" do
                merging_task.required_host = "host"
                merged_task.required_host = "other_host"
                assert !merging_task.can_merge?(merged_task)
            end
        end

        describe "can_be_deployed_by?" do
            before do
                @task_m = Syskit::TaskContext.new_submodel
            end
            describe "services that require reconfiguration" do
                before do
                    srv_m = Syskit::DataService.new_submodel
                    @task_m.dynamic_service srv_m, as: "srv",
                                                   remove_when_unused: true,
                                                   addition_requires_reconfiguration: true do
                        provides srv_m
                    end
                end

                describe "the addition of new services that require reconfiguration" do
                    before do
                        @new_task = @task_m.new
                        @new_task.specialize
                        @new_task.require_dynamic_service "srv", as: "srv"
                        @existing_task = syskit_stub_and_deploy(@task_m)
                    end

                    it "cannot be deployed if the deployment task is configured" do
                        syskit_configure(@existing_task)
                        refute @new_task.can_be_deployed_by?(@existing_task)
                    end
                    it "can be deployed if the deployment task is not configured" do
                        assert @new_task.can_be_deployed_by?(@existing_task)
                    end
                end

                describe "the removal of service that need to be removed" do
                    before do
                        @new_task = @task_m.new
                        @existing_task = syskit_stub_and_deploy(@task_m)
                        @existing_task.specialize
                        @existing_task.require_dynamic_service "srv", as: "srv"
                    end
                    it "cannot be deployed if the deployment task is configured" do
                        syskit_configure(@existing_task)
                        refute @new_task.can_be_deployed_by?(@existing_task)
                    end
                    it "cannot be deployed if the deployment task is not configured" do
                        refute @new_task.can_be_deployed_by?(@existing_task)
                    end
                end
            end
            describe "services that do not require reconfiguration" do
                before do
                    srv_m = Syskit::DataService.new_submodel
                    @task_m.dynamic_service srv_m, as: "srv",
                                                   remove_when_unused: false,
                                                   addition_requires_reconfiguration: false do
                        provides srv_m
                    end
                end

                describe "the addition of new services that require reconfiguration" do
                    before do
                        @new_task = @task_m.new
                        @new_task.specialize
                        @new_task.require_dynamic_service "srv", as: "srv"
                        @existing_task = syskit_stub_and_deploy(@task_m)
                    end

                    it "can be deployed if the existing task is configured" do
                        syskit_configure(@existing_task)
                        assert @new_task.can_be_deployed_by?(@existing_task)
                    end
                    it "can be deployed if the existing task is not configured" do
                        assert @new_task.can_be_deployed_by?(@existing_task)
                    end
                end

                describe "the removal of service that need to be removed" do
                    before do
                        @new_task = @task_m.new
                        @existing_task = syskit_stub_and_deploy(@task_m)
                        @existing_task.specialize
                        @existing_task.require_dynamic_service "srv", as: "srv"
                    end
                    it "cannot be deployed if the existing task is configured" do
                        syskit_configure(@existing_task)
                        assert @new_task.can_be_deployed_by?(@existing_task)
                    end
                    it "cannot be deployed if the existing task is not configured" do
                        assert @new_task.can_be_deployed_by?(@existing_task)
                    end
                end
            end
        end

        stub_process_server_deployment_helpers = Module.new do
            attr_reader :deployment_m, :deployment0, :deployment1
            def setup
                super
                @deployment_m = Deployment.new_submodel
                @stub_process_servers = []
            end

            def teardown
                @stub_process_servers.each do |ps|
                    Syskit.conf.remove_process_server(ps.name)
                end
                super
            end

            def create_task_from_host_id(host_id, name: flexmock)
                process_server = RobyApp::UnmanagedTasksManager.new
                RobyApp::UnmanagedProcess.new(process_server, "test", nil)
                log_dir = flexmock("log_dir")
                process_server_config = Syskit.conf.register_process_server(
                    name, process_server, log_dir, host_id: host_id
                )
                @stub_process_servers << process_server_config
                deployment = deployment_m.new(on: name)
                plan.add(task = task_m.new)
                task.executed_by(deployment)
                task
            end
        end

        describe "#distance_to_syskit" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns D_SAME_PROCESS if the task is on the 'syskit' host_id" do
                task = create_task_from_host_id "syskit"
                assert_equal TaskContext::D_SAME_PROCESS, task.distance_to_syskit
            end
            it "returns D_SAME_HOST if the task is running on localhost" do
                task = create_task_from_host_id "localhost"
                assert_equal TaskContext::D_SAME_HOST, task.distance_to_syskit
            end
            it "returns D_DIFFERENT_HOSTS if the task is not running "\
                "on syskit or localhost" do
                task = create_task_from_host_id "test"
                assert_equal TaskContext::D_DIFFERENT_HOSTS, task.distance_to_syskit
            end
        end

        describe "#in_process" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns true if the task is on the 'syskit' host_id" do
                assert create_task_from_host_id("syskit").in_process?
            end
            it "returns false if the task is running on localhost" do
                refute create_task_from_host_id("localhost").in_process?
            end
            it "returns false if the task is running on any other host_id "\
                "than syskit and localhost" do
                refute create_task_from_host_id("test").in_process?
            end
        end

        describe "#on_localhost" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns true if the task is on the 'syskit' host_id" do
                assert create_task_from_host_id("syskit").on_localhost?
            end
            it "returns true if the task is running on localhost" do
                assert create_task_from_host_id("localhost").on_localhost?
            end
            it "returns false if the task is running on any other host_id "\
                "than syskit and localhost" do
                refute create_task_from_host_id("test").on_localhost?
            end
        end

        describe "#distance_to" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns D_SAME_PROCESS if both tasks are identical" do
                task = create_task_from_host_id "test"
                assert_equal TaskContext::D_SAME_PROCESS, task.distance_to(task)
            end
            it "returns D_SAME_PROCESS if both tasks are from the same process" do
                task0 = create_task_from_host_id "test"
                task1 = task_m.new
                task1.executed_by(task0.execution_agent)
                assert_equal TaskContext::D_SAME_PROCESS, task0.distance_to(task1)
            end
            it "returns D_SAME_HOST if both tasks are from processes on the same host" do
                task0 = create_task_from_host_id "test"
                task1 = create_task_from_host_id "test"
                assert_equal TaskContext::D_SAME_HOST, task0.distance_to(task1)
            end
            it "returns D_DIFFERENT_HOSTS if both tasks are from processes "\
                "from different hosts" do
                task0 = create_task_from_host_id "here"
                task1 = create_task_from_host_id "there"
                assert_equal TaskContext::D_DIFFERENT_HOSTS, task0.distance_to(task1)
            end
            it "returns nil if one of the two tasks has no execution agent" do
                task0 = create_task_from_host_id "here"
                plan.add(task = TaskContext.new_submodel.new)
                assert !task.distance_to(task0)
                assert !task0.distance_to(task)
            end
        end

        describe "#find_input_port" do
            attr_reader :task
            before do
                @task = syskit_stub_deploy_and_configure "Task" do
                    input_port "in", "int"
                    output_port "out", "int"
                end
            end

            it "should return the port from #orocos_task if it exists" do
                Runkit.allow_blocking_calls do
                    assert_equal task.orocos_task.port("in"),
                                 task.find_input_port("in").to_orocos_port
                end
            end
            it "should return nil for an output port" do
                assert_nil task.find_input_port("out")
            end
            it "should return nil for a port that does not exist" do
                assert_nil task.find_input_port("does_not_exist")
            end
        end

        describe "#find_output_port" do
            attr_reader :task
            before do
                @task = syskit_stub_deploy_and_configure "Task" do
                    input_port "in", "int"
                    output_port "out", "int"
                end
            end

            it "should return the port from #orocos_task if it exists" do
                Runkit.allow_blocking_calls do
                    assert_equal task.orocos_task.port("out"),
                                 task.find_output_port("out").to_orocos_port
                end
            end
            it "should return nil for an input port" do
                assert_nil task.find_output_port("in")
            end
            it "should return nil for a port that does not exist" do
                assert_nil task.find_output_port("does_not_exist")
            end
        end

        describe "start_event" do
            attr_reader :task, :task_m, :orocos_task
            before do
                @task_m = TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
                end
                task = syskit_stub_deploy_and_configure(task_m)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            after do
                if task.start_event.pending?
                    task.start_event.emit
                end
                if task.running?
                    expect_execution { task.stop! }
                        .to { emit task.stop_event }
                end
            end

            def start_task
                expect_execution { task.start! }
                    .to { emit task.start_event }
            end

            it "queues start for the underlying task" do
                orocos_task.should_receive(:start).once.pass_thru
                start_task
            end
            it "checks that all required output ports are present" do
                task.should_receive(:each_concrete_output_connection)
                    .and_return([[port = Object.new]]).once
                orocos_task.should_receive(:port_names).and_return([port]).once
                start_task
            end
            it "raises Runkit::NotFound if some required output ports are not present" do
                task.should_receive(:each_concrete_output_connection)
                    .and_return([[Object.new]]).once
                orocos_task.should_receive(:start).never
                expect_execution { task.start! }
                    .to do
                        fail_to_start task, reason: Roby::EmissionFailed.match
                                                                        .with_original_exception(Runkit::NotFound)
                    end
            end
            it "checks that all required input ports are present" do
                task.should_receive(:each_concrete_input_connection)
                    .and_return([[nil, nil, port = Object.new, nil]])
                orocos_task.should_receive(:port_names).and_return([port]).once
                start_task
            end
            it "raises Runkit::NotFound if some required input ports are not present" do
                task.should_receive(:each_concrete_input_connection)
                    .and_return([[nil, nil, Object.new, nil]])
                orocos_task.should_receive(:port_names).once.and_return([])
                orocos_task.should_receive(:start).never
                expect_execution { task.start! }
                    .to do
                        fail_to_start task, reason: Roby::EmissionFailed.match
                                                                        .with_original_exception(Runkit::NotFound)
                    end
            end
            it "emits the start event once the state reader reported the RUNNING state" do
                FlexMock.use(task.state_reader) do |state_reader|
                    state = nil
                    state_reader.should_receive(:read_new)
                                .and_return do
                        s = state
                        state = nil
                        s
                    end
                    execute { task.start! }
                    refute task.running?
                    state = :RUNNING
                    expect_execution.to { emit task.start_event }
                    # Just to shut up sanity checks with state events
                    state = :STOPPED
                    expect_execution.to { emit task.stop_event }
                end
            end
            it "fails to start if orocos_task#start raises an exception" do
                error_m = Class.new(RuntimeError)
                orocos_task.should_receive(:start).once.and_raise(error_m)
                expect_execution { task.start! }
                    .to do
                        fail_to_start task, reason: Roby::EmissionFailed.match
                                                                        .with_original_exception(error_m)
                    end
            end
        end

        describe "#state_event" do
            it "resolves events from parent models" do
                parent_m = TaskContext.new_submodel do
                    runtime_states :CUSTOM
                end
                child_m = parent_m.new_submodel
                child = child_m.new
                assert_equal :custom, child.state_event(:CUSTOM)
            end
        end

        describe "stop_event" do
            attr_reader :task, :orocos_task
            before do
                @task = syskit_stub_deploy_configure_and_start(TaskContext.new_submodel)
                @orocos_task = flexmock(task.orocos_task)
            end

            it "is not emitted by the interruption command" do
                expect_execution { task.stop! }
                    .timeout(0).to { not_emit task.stop_event }
                assert task.finishing?
            end
            it "is quarantined if orocos_task#stop raises ComError" do
                orocos_task.should_receive(:stop).and_raise(Runkit::ComError)
                expect_execution { task.stop! }
                    .to do
                        quarantine task
                        ignore_errors_from(have_error_matching(Roby::EmissionFailed))
                        emit task.aborted_event
                    end
            end
            it "emits interrupt if orocos_task#stop raises StateTransitionFailed "\
                "but the task is in a stopped state" do
                task.orocos_task.should_receive(:stop).and_return do
                    Runkit::TaskContext.instance_method(:stop)
                                       .call(task.orocos_task)
                    raise Runkit::StateTransitionFailed
                end
                expect_execution { task.stop! }
                    .to { emit task.interrupt_event }
            end
            it "is stopped when the stop event is received" do
                expect_execution { task.stop! }
                    .to { emit task.stop_event }
            end
        end

        describe "#handle_state_changes" do
            attr_reader :task, :task_m, :orocos_task
            before do
                @task_m = TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
                    reports :blabla

                    event :test
                end
                task = syskit_stub_deploy_and_configure(task_m)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            after do
                if task.start_event.pending?
                    task.start_event.emit
                end
                if task.running?
                    expect_execution { task.stop! }
                        .to { emit task.stop_event }
                end
            end

            it "does nothing if no runtime state has been received" do
                task.should_receive(:orogen_state).and_return(:exception)
                orocos_task.should_receive(:runtime_state?).with(:exception)
                           .and_return(false)
                task.handle_state_changes
                expect_execution.to do
                    not_emit task.start_event
                end
            end
            it "emits start as soon as a runtime state has been received, "\
                "and emits the event mapped by #state_event" do
                task.should_receive(:orogen_state).and_return(:blabla)
                orocos_task.should_receive(:runtime_state?).with(:blabla)
                           .and_return(true)
                task.should_receive(:state_event).with(:blabla).and_return(:test)
                expect_execution { task.handle_state_changes }
                    .to do
                        emit task.start_event
                        emit task.test_event
                    end
            end
            it "raises ArgumentError if the state cannot be mapped to an event" do
                syskit_start(task)
                task.should_receive(:orogen_state).and_return(:blabla)
                task.should_receive(:state_event).and_return(nil)
                e = assert_raises(ArgumentError) do
                    task.handle_state_changes
                end
                assert_equal "#{task} reports state blabla, but I don't have an event "\
                    "for this state transition", e.message
            end
            it "emits the 'running' event when transitioning out of an error state" do
                syskit_start(task)
                task.should_receive(:last_orogen_state).and_return(:BLA)
                orocos_task.should_receive(:error_state?)
                           .with(:BLA).once.and_return(true)
                expect_execution { task.handle_state_changes }
                    .to { emit task.running_event }
                assert_equal 2, task.running_event.history.size
            end
            it "does not emit the 'running' event if the last state "\
                "was not an error state" do
                syskit_start(task)
                task.should_receive(:last_orogen_state).and_return(:BLA)
                orocos_task.should_receive(:error_state?)
                           .with(:BLA).once.and_return(false)
                task.handle_state_changes
                expect_execution.to { not_emit task.running_event }
            end
        end

        describe "#update_orogen_state" do
            attr_reader :task, :orocos_task
            before do
                @task_m = TaskContext.new_submodel
                task = syskit_stub_and_deploy(@task_m)
                @task = flexmock(task)
                syskit_start_execution_agents(task)
                @orocos_task = flexmock(task.orocos_task)
                setup_task_state_queue(task)
            end

            def setup_task_state_queue(task)
                flexmock(task.state_reader)
                @current_state = nil
                @state_queue = []
                task.state_reader.should_receive(:read)
                    .at_most.once
                    .by_default
                    .and_return do
                        if @state_queue.empty?
                            @current_state
                        else
                            @current_state = @state_queue.shift
                        end
                    end
                task.state_reader.should_receive(:read_new)
                    .by_default
                    .and_return { @current_state = @state_queue.shift }
            end

            def push_task_state(state)
                @state_queue << state
            end

            # NOTE: handling of errors related to the state readers is done
            # in live/test_state_reader_disconnection.rb

            it "is provided a connected state reader by its execution agent" do
                assert task.state_reader.connected?
            end
            it "reads the last known state on initialization "\
               "if there is no state transition" do
                task.state_reader.should_receive(:read_new).and_return(nil)
                task.state_reader.should_receive(:read).and_return(state = Object.new)
                assert_equal state, task.update_orogen_state
                refute task.last_orogen_state
            end
            it "does not read the last known state once it is initialized" do
                task.state_reader.should_receive(:read)
                    .once.and_return(state = Object.new)
                task.state_reader.should_receive(:read_new)
                    .once.and_return(nil)
                assert_equal state, task.update_orogen_state
                assert_nil task.update_orogen_state
            end
            it "sets orogen_state with the new state" do
                push_task_state(state = Object.new)
                task.update_orogen_state
                assert_equal state, task.orogen_state
            end
            it "updates last_orogen_state with the current state" do
                push_task_state(last_state = Object.new)
                push_task_state(Object.new)
                task.update_orogen_state
                task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
            end
            it "returns nil if no new state has been received" do
                refute task.update_orogen_state
            end
            it "does not change the last and current states if no new states "\
                "have been received" do
                push_task_state(last_state = Object.new)
                push_task_state(state = Object.new)
                push_task_state(nil)
                task.update_orogen_state
                task.update_orogen_state
                refute task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
                assert_equal state, task.orogen_state
            end
            it "returns the new state if there is one" do
                push_task_state(state = Object.new)
                assert_equal state, task.update_orogen_state
            end
            it "emits the exception event when transitioned to exception" do
                task = syskit_stub_deploy_configure_and_start(@task_m, remote_task: false)
                expect_execution { task.orocos_task.exception }
                    .to { emit task.exception_event }
            end
        end

        describe "#ready_for_setup?" do
            attr_reader :task, :orocos_task
            before do
                task = syskit_stub_and_deploy("Task") {}
                syskit_start_execution_agents(task)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            it "returns true for a fully instanciated task whose state "\
                "is PRE_OPERATIONAL" do
                assert task.ready_for_setup?
            end
            it "returns false if a task context representing the same component "\
                "is being configured" do
                task = syskit_stub_and_deploy "ConcurrentConfigurationTask"
                syskit_start_execution_agents(task)
                plan.add_permanent_task(
                    other_task = task.execution_agent.task(task.orocos_name)
                )
                assert task.ready_for_setup?
                other_task.setup.execute
                refute task.ready_for_setup?
                execution_engine.join_all_waiting_work
                assert task.ready_for_setup?
            end
            it "returns true if a task context representing the same component "\
                "has started configuring and the configuration failed" do
                task = syskit_stub_and_deploy "ConcurrentConfigurationTask"
                syskit_start_execution_agents(task)
                plan.add(other_task = task.execution_agent.task(task.orocos_name))
                assert task.ready_for_setup?
                flexmock(other_task.orocos_task).should_receive(:configure)
                                                .and_raise(Runkit::StateTransitionFailed)
                other_task.setup.execute
                refute task.ready_for_setup?
                execution_engine.join_all_waiting_work
                assert task.ready_for_setup?
            end
            it "returns false if the task has been marked as garbage" do
                execute { task.garbage! }
                refute task.ready_for_setup?
            end
            it "returns false if task arguments are not set" do
                task.should_receive(:fully_instanciated?).and_return(false)
                refute task.ready_for_setup?
            end
            it "returns false if the task has no orogen model yet" do
                task.should_receive(:orogen_model)
                refute task.ready_for_setup?
            end
            it "returns false if the task has no orocos task yet" do
                task.should_receive(:orocos_task)
                refute task.ready_for_setup?
            end
            it "returns false if the task's current state cannot be read" do
                task.should_receive(:read_current_state).and_return(nil)
                refute task.ready_for_setup?
            end
            it "returns false if the task's current state is not one "\
                "from which we can configure" do
                task.should_receive(:read_current_state).and_return(Object.new)
                refute task.ready_for_setup?
            end
            it "returns true if the task's current state is an exception state" do
                task.should_receive(:read_current_state).and_return(state = Object.new)
                flexmock(task.orocos_task).should_receive(:exception_state?)
                                          .with(state).and_return(true)
                assert task.ready_for_setup?
            end
            it "returns true if the task's current state is STOPPED" do
                task.should_receive(:read_current_state).and_return(:STOPPED)
                assert task.ready_for_setup?
            end
            it "returns true if the task's current state is PRE_OPERATIONAL" do
                task.should_receive(:read_current_state).and_return(:STOPPED)
                assert task.ready_for_setup?
            end

            it "returns false if the task is read_only and the component is not running" do
                task.should_receive(:read_only?).and_return(true)
                refute task.ready_for_setup?
            end

            it "returns true if the task is read_only and the component is in a running "\
               "state" do
                task.should_receive(:read_only?).and_return(true)
                orocos_task.should_receive(:runtime_state?)
                           .and_return(true)
                assert task.ready_for_setup?
            end
        end

        describe "#read_current_state" do
            attr_reader :task, :state_reader
            before do
                @task = syskit_stub_and_deploy("Task") {}
                syskit_start_execution_agents(task)
                @state_reader = flexmock(task.state_reader)
            end
            it "returns nil if both #read and #read_new return nil" do
                state_reader.should_receive(:read_new).and_return(nil).once
                state_reader.should_receive(:read).and_return(nil).once
                assert_nil task.read_current_state
            end
            it "returns the value of the last non-nil #read_new" do
                state_reader.should_receive(:read_new).and_return(1, 2, 3, nil)
                assert_equal 3, task.read_current_state
            end
            it "returns the value of #read if #read_new returns nil" do
                state_reader.should_receive(:read_new).and_return(nil)
                state_reader.should_receive(:read).and_return(3)
                assert_equal 3, task.read_current_state
            end
        end

        describe "#setup_successful!" do
            attr_reader :task
            before do
                task = syskit_stub_and_deploy(TaskContext.new_submodel)
                syskit_start_execution_agents(task)
                @task = flexmock(task)
                assert !task.executable?
            end
            it "resets the executable flag if all inputs are connected" do
                task.should_receive(:all_inputs_connected?).and_return(true).once
                task.setup_successful!
                assert task.executable?
            end
            it "does not reset the executable flag if some inputs are not connected" do
                task.should_receive(:all_inputs_connected?).and_return(false).once
                task.setup_successful!
                assert !task.executable?
            end
        end

        describe "#reusable?" do
            it "is false if the task is setup and needs reconfiguration" do
                task = flexmock(TaskContext.new_submodel.new)
                assert task.reusable?
                task.should_receive(:setup?).and_return(true)
                task.should_receive(:needs_reconfiguration?).and_return(true)
                assert !task.reusable?
            end
        end

        describe "needs_reconfiguration" do
            attr_reader :task_m
            before do
                @task_m = TaskContext.new_submodel
            end
            it "is false if the task does not have a supporting execution agent" do
                t0 = task_m.new
                refute t0.needs_reconfiguration?
            end
            it "is false if the task's execution agent is not ready" do
                t0 = syskit_stub_and_deploy(task_m)
                refute t0.needs_reconfiguration?
            end
            it "is false once the task's execution agent is ready" do
                t0 = syskit_stub_and_deploy(task_m)
                syskit_start_execution_agents(t0)
                refute t0.needs_reconfiguration?
            end
            it "sets the reconfiguration flag to true for a given orocos name" do
                t0 = syskit_stub_and_deploy(task_m)
                syskit_start_execution_agents(t0)
                t1 = t0.execution_agent.task(t0.orocos_name)
                t0.needs_reconfiguration!
                assert t1.needs_reconfiguration?
            end
        end

        describe "#clean_dynamic_port_connections" do
            it "removes connections that relate to the task's dynamic input ports" do
                srv_m = DataService.new_submodel { input_port "p", "/double" }
                task_m = TaskContext.new_submodel do
                    orogen_model.dynamic_input_port(/.*/, "/double")
                end
                task_m.dynamic_service srv_m, as: "test" do
                    provides srv_m, "p" => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service "test", as: "test"
                source_task = syskit_stub_deploy_and_configure "SourceTask",
                                                               as: "source_task" do
                    input_port "dynamic", "/double"
                end
                orocos_tasks = [source_task.orocos_task, task.orocos_task]

                ActualDataFlow.add_connections(*orocos_tasks,
                                               Hash[%w[dynamic dynamic] => [{}, false, false]])
                assert ActualDataFlow.has_edge?(*orocos_tasks)
                task.clean_dynamic_port_connections([])
                assert !ActualDataFlow.has_edge?(*orocos_tasks)
            end
            it "removes connections that relate to the task's dynamic output ports" do
                srv_m = DataService.new_submodel { output_port "p", "/double" }
                task_m = TaskContext.new_submodel do
                    orogen_model.dynamic_output_port(/.*/, "/double")
                end
                task_m.dynamic_service srv_m, as: "test" do
                    provides srv_m, "p" => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service "test", as: "test"

                sink_task =
                    syskit_stub_deploy_and_configure "SinkTask", as: "sink_task" do
                        output_port "dynamic", "/double"
                    end
                orocos_tasks = [task.orocos_task, sink_task.orocos_task]

                ActualDataFlow.add_connections(*orocos_tasks,
                                               Hash[%w[dynamic dynamic] => [{}, false, false]])
                assert ActualDataFlow.has_edge?(*orocos_tasks)
                task.clean_dynamic_port_connections([])
                refute ActualDataFlow.has_edge?(*orocos_tasks)
            end
        end

        describe "reconfiguration behavior" do
            describe "without #update_properties" do
                attr_reader :task_m
                before do
                    @task_m =
                        RubyTaskContext.new_submodel(name: "#{class_name}##{name}") do
                            property "config", "/double", 0
                        end
                    flexmock(@task_m, use_update_properties?: false)
                end

                it "resets an exception state" do
                    warmup_to_exception

                    task = syskit_deploy(task_m.deployed_as(name, on: "stubs"))
                    flexmock(task.orocos_task)
                        .should_receive(:reset_exception)
                        .once.ordered.pass_thru
                    flexmock(task)
                        .should_receive(:clean_dynamic_port_connections)
                        .once.ordered.pass_thru

                    messages = configure_task_with_capture(task)
                    assert_includes(
                        messages,
                        "reconfiguring #{task}: the task was in exception state"
                    )
                end
                it "does not cleanup a never-configured task" do
                    task = deploy_task
                    syskit_start_execution_agents(task)
                    flexmock(task.orocos_task).should_receive(:cleanup).never
                    messages = configure_task_with_capture(task)
                    assert_includes messages, "setting up #{task}"
                end
                it "does not reconfigure a task whose configuration has not changed" do
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).never
                    task.should_receive(:clean_dynamic_port_connections).never
                    messages = configure_task_with_capture(task)
                    assert_includes(
                        messages,
                        "not reconfiguring #{task}: the task is already configured "\
                        "as required"
                    )
                end
                it "reconfigures a task with non-default configuration" do
                    # This is essentially a bug, enshrined in a unit test. Fixing
                    # that required a non-obvious, non-backward-compatible fix
                    #
                    # See https://www.rock-robotics.org/rock-and-syskit/deprecations/update_properties.html
                    @task_m.define_method :configure do
                        super()
                        properties.config = 10
                    end
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    messages = configure_task_with_capture(task)
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures a task whose properties need to be updated" do
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    Runkit.allow_blocking_calls { task.orocos_task.config = 10 }
                    messages = configure_task_with_capture(task)
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures a task which is explicitly marked as needing to" do
                    warmup_to_configure

                    task = deploy_task
                    task.needs_reconfiguration!
                    messages = configure_task_with_capture(task)
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures a task which was previously explicitly "\
                   "marked as needing to" do
                    warmup_to_configure(&:needs_reconfiguration!)

                    task = deploy_task
                    messages = configure_task_with_capture(task)
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures if the state is STOPPED but the task "\
                   "has never been configured by Syskit" do
                    task = deploy_task
                    syskit_start_execution_agents(task)
                    Runkit.allow_blocking_calls { task.orocos_task.configure }

                    flexmock(task.orocos_task).should_receive(:cleanup).once.ordered
                    task.should_receive(:clean_dynamic_port_connections).once.ordered
                    configure_task_with_capture(task)
                end
                it "reconfigures if the selected configuration changed" do
                    syskit_stub_conf(@task_m, "test")
                    warmup_to_configure

                    task = deploy_task(conf: %w[default test])
                    task.orocos_task.should_receive(:cleanup).once
                    configure_task_with_capture(task)
                end
                it "reconfigures if the properties have been changed" do
                    warmup_to_configure

                    task = deploy_task
                    def task.configure
                        super
                        properties.config = 10
                    end

                    task.orocos_task.should_receive(:cleanup).once.ordered
                    configure_task_with_capture(task)
                end

                def configure_task_with_capture(task)
                    capture_log(task, :info) do
                        # Capture deprecation warnings
                        capture_log(task, :warn) { syskit_configure(task) }
                    end
                end
            end

            describe "with #update_properties" do
                attr_reader :task_m
                before do
                    @task_m = RubyTaskContext.new_submodel(name: name.upcase) do
                        property "config", "/double", 0
                    end
                    flexmock(@task_m, use_update_properties?: true)
                end

                it "resets an exception state" do
                    warmup_to_exception

                    task = syskit_deploy(task_m.deployed_as(name, on: "stubs"))
                    flexmock(task.orocos_task)
                        .should_receive(:reset_exception)
                        .once.ordered.pass_thru
                    flexmock(task)
                        .should_receive(:clean_dynamic_port_connections)
                        .once.ordered.pass_thru

                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes(
                        messages,
                        "reconfiguring #{task}: the task was in exception state"
                    )
                end
                it "does not cleanup a never-configured task" do
                    task = deploy_task
                    syskit_start_execution_agents(task)
                    flexmock(task.orocos_task).should_receive(:cleanup).never
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes messages, "setting up #{task}"
                end
                it "does not reconfigure a task whose configuration has not changed" do
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).never
                    task.should_receive(:clean_dynamic_port_connections).never
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes(
                        messages,
                        "not reconfiguring #{task}: the task is already configured "\
                        "as required"
                    )
                end
                it "does no reconfigure a task with an unchanged but "\
                   "non-default configuration" do
                    # This is a regression test. The pre-update_properties world
                    # would reconfigure a task if its configuration was non-default
                    #
                    # The fix was to introduce update_properties
                    @task_m.define_method :update_properties do
                        super()
                        properties.config = 10
                    end
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).never
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes(
                        messages,
                        "not reconfiguring #{task}: the task is already configured "\
                        "as required"
                    )
                end
                it "reconfigures a task whose properties need to be updated" do
                    warmup_to_configure

                    task = deploy_task
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    Runkit.allow_blocking_calls { task.orocos_task.config = 10 }
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures a task which is explicitly marked as needing to" do
                    warmup_to_configure

                    task = deploy_task
                    task.needs_reconfiguration!
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures a task which was previously explicitly "\
                   "marked as needing to" do
                    warmup_to_configure(&:needs_reconfiguration!)

                    task = deploy_task
                    messages = capture_log(task, :info) { syskit_configure(task) }
                    assert_includes messages, "cleaning up #{task}"
                end
                it "reconfigures if the state is STOPPED but the task "\
                   "has never been configured by Syskit" do
                    task = deploy_task
                    syskit_start_execution_agents(task)
                    Runkit.allow_blocking_calls { task.orocos_task.configure }

                    flexmock(task.orocos_task).should_receive(:cleanup).once.ordered
                    task.should_receive(:clean_dynamic_port_connections).once.ordered
                    capture_log(task, :info) { syskit_configure(task) }
                end
                it "reconfigures if the selected configuration changed" do
                    syskit_stub_conf(@task_m, "test")
                    warmup_to_configure

                    task = deploy_task(conf: %w[default test])
                    task.orocos_task.should_receive(:cleanup).once
                    capture_log(task, :info) { syskit_configure(task) }
                end
                it "reconfigures if the properties have been changed" do
                    warmup_to_configure

                    task = deploy_task
                    def task.configure
                        super
                        properties.config = 10
                    end

                    task.orocos_task.should_receive(:cleanup).once.ordered
                    capture_log(task, :info) { syskit_configure(task) }
                end
            end

            describe "handling of dynamic ports" do
                attr_reader :task_m
                before do
                    @task_m = RubyTaskContext.new_submodel(name: name.upcase) do
                        property "config", "/double", 0

                        output_port "out", "/double"
                        input_port "in", "/double"
                    end
                end

                it "cleans connections with dynamic ports after a #cleanup" do
                    warmup_to_configure do |task|
                        task.orocos_task.create_output_port "dynout", "/double"
                        task.orocos_task.create_input_port "dynin", "/double"
                        task.needs_reconfiguration!
                    end

                    task = deploy_task
                    Runkit.allow_blocking_calls { task.orocos_task }
                    task.orocos_task.should_receive(:cleanup).once
                        .pass_thru do
                            %w[dynin dynout].each do |port_name|
                                task.orocos_task.remove_port(
                                    task.orocos_task.port(port_name)
                                )
                            end
                        end

                    ports = nil
                    task.should_receive(:clean_dynamic_port_connections)
                        .with(->(p) { ports = p }).once

                    capture_log(task, :info) { syskit_configure(task) }
                    assert_equal Set["state", "out", "in"], ports.to_set
                end

                it "cleans connections with dynamic ports after #reset_exception" do
                    warmup_to_exception

                    port_names = []
                    task = deploy_task
                    task.orocos_task.should_receive(:port_names).and_return { port_names }
                    task.orocos_task.should_receive(:reset_exception)
                        .and_return { port_names = ["test"] }
                    task.should_receive(:clean_dynamic_port_connections)
                        .with(["test"]).once

                    capture_log(task, :info) { syskit_configure(task) }
                end
            end

            describe "handling of dynamic services" do
                before do
                    srv_m = DataService.new_submodel
                    srv2_m = DataService.new_submodel
                    @task_m = RubyTaskContext.new_submodel(name: "Test")
                    @task_m.dynamic_service srv_m, as: "test" do
                        provides srv_m, as: name
                    end
                    @task_m.dynamic_service srv_m, as: "test_alt" do
                        provides srv_m, as: name
                    end
                    @task_m.dynamic_service srv2_m, as: "test2" do
                        provides srv2_m, as: name
                    end

                    test1_m = @task_m.specialize
                    test1_m.require_dynamic_service "test", as: "test1"
                    warmup(test1_m) { |task| syskit_configure(task) }
                end

                it "does not reconfigure a task whose list of dynamic services "\
                   "did not change" do
                    # NOTE: we explicitly re-specialize the model. From syskit's
                    # perspective the two specialized models are equivalent
                    test2_m = @task_m.specialize
                    test2_m.require_dynamic_service "test", as: "test1"
                    task = deploy_task(test2_m)
                    task.orocos_task.should_receive(:cleanup).never
                    syskit_configure(task)
                end

                it "reconfigures a task if two dynamic services have the same model "\
                   "and name, but not arguments" do
                    # NOTE: we explicitly re-specialize the model. From syskit's
                    # perspective the two specialized models are equivalent
                    test2_m = @task_m.specialize
                    test2_m.require_dynamic_service "test", as: "test1", some: "arg"
                    task = deploy_task(test2_m)
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    syskit_configure(task)
                end

                it "reconfigures a task if two dynamic services have the same name "\
                   "and model, but from a different dynamic service" do
                    # NOTE: we explicitly re-specialize the model. From syskit's
                    # perspective the two specialized models are equivalent
                    test2_m = @task_m.specialize
                    test2_m.require_dynamic_service "test_alt", as: "test1"
                    task = deploy_task(test2_m)
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    syskit_configure(task)
                end

                it "reconfigures a task if two dynamic services have the same name "\
                   "but the model differs" do
                    # NOTE: we explicitly re-specialize the model. From syskit's
                    # perspective the two specialized models are equivalent
                    test2_m = @task_m.specialize
                    test2_m.require_dynamic_service "test2", as: "test1"
                    task = deploy_task(test2_m)
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    syskit_configure(task)
                end

                it "reconfigures a task whose list of dynamic services changed" do
                    # NOTE: it is up to the deployment algorithm to decide whether
                    # tasks have their list of dynamic services changed.
                    #
                    # At the point of the task's configuration, this decision
                    # has been made The reconfiguration logic should just follow
                    # it
                    test2_m = @task_m.specialize
                    test2_m.require_dynamic_service "test", as: "test2"
                    task = deploy_task(test2_m)
                    task.orocos_task.should_receive(:cleanup).once.pass_thru
                    syskit_configure(task)
                end
            end

            def deploy_task(model = @task_m, **arguments)
                task_m = model.with_arguments(**arguments)
                              .deployed_as(name, on: "stubs")
                task = syskit_deploy(task_m)
                flexmock(task)
                flexmock(task.orocos_task)
                task
            end

            def warmup(model = @task_m, **arguments)
                # Warm things up
                task = deploy_task(model, **arguments)
                yield(task)
                expect_execution { plan.make_useless(task) }
                    .garbage_collect(true).to { finalize task }
            end

            def warmup_to_configure
                warmup do |task|
                    capture_log(task, :warn) { syskit_configure(task) }
                    yield(task) if block_given?
                end
            end

            def warmup_to_exception
                warmup do |task|
                    capture_log(task, :warn) { syskit_configure_and_start(task) }
                    Runkit.allow_blocking_calls { task.orocos_task.exception }
                    expect_execution.to { emit task.stop_event }
                end
            end
        end

        describe "#setup" do
            attr_reader :task, :orocos_task, :recorder
            before do
                @recorder = flexmock
                recorder.should_receive(:called)
                recorder.should_receive(:error).never.by_default
                task = syskit_stub_and_deploy "Task" do
                    input_port "in", "int"
                    output_port "out", "int"
                end
                syskit_start_execution_agents(task, recursive: true)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            def default_setup_task_messages(task)
                ["applied configuration [\"default\"] to #{task.orocos_name}", "setting up #{task}"]
            end

            def setup_task(task = self.task, expected_messages: nil)
                promise = nil
                messages = capture_log(task, :info) do
                    promise = task.setup.execute
                    expect_execution.to { achieve { task.setup? } }
                end
                expected_messages ||= default_setup_task_messages(task)
                assert_equal expected_messages, messages
                promise.value!
            end

            it "freezes delayed arguments" do
                execute { plan.remove_task(task) }
                task = Test::StubNetwork.new(self, stubs: @__stubs)
                                        .stub_deployment(TaskContext.new_submodel.new)
                plan.add_permanent_task(task)
                syskit_start_execution_agents(task)
                assert_nil task.arguments[:conf]
                setup_task(task)
                assert_equal ["default"], task.arguments[:conf]
            end

            it "resets the needs_configuration flag" do
                orocos_task.should_receive(:read_toplevel_state).and_return(:PRE_OPERATIONAL)
                task.should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
                task.needs_reconfiguration!
                setup_task
                assert !task.needs_reconfiguration?
            end
            it "registers the current task configuration" do
                orocos_task.should_receive(:read_toplevel_state).and_return(:PRE_OPERATIONAL)
                task.should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
                task.needs_reconfiguration!
                assert task.execution_agent.configuration_changed?(task.orocos_name, ["default"], Set.new)
                setup_task
                refute task.execution_agent.configuration_changed?(task.orocos_name, ["default"], Set.new)
            end
            it "reports an exception from the user-provided #configure method as failed-to-start" do
                task.should_receive(:configure).and_raise(error_e = Class.new(RuntimeError))

                promise = task.setup
                expect_execution { promise.execute }
                    .to do
                        fail_to_start task, reason: Roby::EmissionFailed.match
                                                                        .with_origin(task.start_event)
                                                                        .with_original_exception(error_e)
                    end
            end
            it "keeps the task in the plan until the asynchronous setup is finished" do
                plan.unmark_mission_task(task)
                expect_execution.scheduler(true).garbage_collect(true).join_all_waiting_work(false).to do
                    achieve { task.setup? }
                end
                expect_execution.garbage_collect(true).to do
                    finalize task
                end
            end
            it "keeps the task in the plan until the asynchronous setup's error has been handled" do
                flexmock(task).should_receive(:configure).and_return do
                    sleep 0.1
                    raise RuntimeError
                end
                flexmock(task.start_event).should_receive(:emit_failed)
                                          .pass_thru do |ret|
                    refute task.can_finalize?
                    ret
                end

                plan.unmark_mission_task(task)
                expect_execution.scheduler(true).join_all_waiting_work(false).garbage_collect(true).to do
                    fail_to_start task
                end
            end
            describe "ordering related to prepare_for_setup" do
                attr_reader :error_m

                before do
                    @error_m = Class.new(RuntimeError)
                    task.should_receive(:prepare_for_setup).once
                        .and_return { |promise| promise }
                end

                it "calls the user-provided #configure method after prepare_for_setup" do
                    task.should_receive(:configure).once.ordered
                    setup_task(expected_messages: ["setting up #{task}"])
                end
                it "calls the task's configure method if the task's state is PRE_OPERATIONAL" do
                    orocos_task.should_receive(:read_toplevel_state).and_return(:PRE_OPERATIONAL)
                    orocos_task.should_receive(:configure).once.ordered
                    setup_task(expected_messages: ["setting up #{task}"])
                end
                it "does not call the task's configure method if the task's state is not PRE_OPERATIONAL" do
                    orocos_task.should_receive(:read_toplevel_state).and_return(:STOPPED)
                    orocos_task.should_receive(:configure).never
                    setup_task(expected_messages: ["#{task} was already configured"])
                end
                it "does not call the task's configure method if the user-provided configure method raises" do
                    task.should_receive(:configure).and_raise(error_m)
                    orocos_task.should_receive(:configure).never

                    promise = task.setup
                    expect_execution { promise.execute }
                        .to do
                            finish_promise promise
                            fail_to_start task, reason: Roby::EmissionFailed.match.with_original_exception(error_m)
                        end
                end
            end
        end
        describe "configuration" do
            it "applies the selected configuration" do
                task_m = TaskContext.new_submodel name: "Task" do
                    property "v", "/int"
                end
                task = syskit_stub_and_deploy(task_m.with_conf("my", "conf"))
                flexmock(task.model.configuration_manager)
                    .should_receive(:conf)
                    .with(%w[my conf], true)
                    .once
                    .and_return("v" => 10)

                syskit_configure(task)
                Runkit.allow_blocking_calls do
                    assert_equal 10, task.orocos_task.v
                end
            end
        end

        describe "interrupt_event" do
            attr_reader :task, :orocos_task, :deployment
            it "calls stop on the task if it has an execution agent in nominal state" do
                task = syskit_stub_deploy_configure_and_start(TaskContext.new_submodel)
                flexmock(task.orocos_task).should_receive(:stop).once.pass_thru
                expect_execution { task.interrupt! }
                    .to { emit task.stop_event }
            end
        end

        describe "#deployment_hints" do
            describe "the behaviour for device drivers" do
                let(:component_hint) { flexmock }
                let(:device_hint) { flexmock }
                let(:task) do
                    device_m = Device.new_submodel
                    task_m = TaskContext.new_submodel
                    task_m.driver_for device_m, as: "test"
                    dev = robot.device(device_m, as: "test").prefer_deployed_tasks(device_hint)
                    task_m.new(test_dev: dev)
                end

                it "uses the hints from its own requirements if there are some" do
                    task.requirements.deployment_hints << component_hint
                    assert_equal [component_hint], task.deployment_hints.to_a
                end

                it "uses the hints from its attached devices if there are none in the requirements" do
                    assert_equal [device_hint], task.deployment_hints.to_a
                end
            end
        end

        it "should synchronize the startup of communication busses and their supported devices" do
            combus_m = ComBus.new_submodel message_type: "/int"
            combus_driver_m = TaskContext.new_submodel(name: "BusDriver") do
                dynamic_output_port(/.*/, "/int")
            end
            combus_driver_m.provides combus_m, as: "driver"
            device_m = Device.new_submodel
            device_driver_m = TaskContext.new_submodel(name: "Driver") do
                input_port "bus_in", "/int"
            end
            device_driver_m.provides combus_m.client_in_srv, as: "bus"
            device_driver_m.provides device_m, as: "driver"

            bus = robot.com_bus combus_m, as: "bus"
            dev = robot.device device_m, as: "dev"
            dev.attach_to(bus, client_to_bus: false)

            # Now, deploy !
            syskit_stub_configured_deployment(combus_driver_m, "bus_task", remote_task: false)
            syskit_stub_configured_deployment(device_driver_m, "dev_task")
            dev_driver = syskit_deploy(dev)
            bus_driver = plan.find_tasks(combus_driver_m).first
            syskit_start_execution_agents(bus_driver)
            syskit_start_execution_agents(dev_driver)

            mock_logger = flexmock(:level= => nil, :level => Logger::INFO, :debug => nil)
            bus_driver.logger = dev_driver.logger = mock_logger
            messages = capture_log(mock_logger, :info) do
                bus_driver.orocos_task.create_output_port "dev", "/int"
                flexmock(bus_driver.orocos_task, "bus").should_receive(:start).once.globally.ordered(:setup).pass_thru
                mock_raw_port(bus_driver.orocos_task, "dev").should_receive(:connect_to).once.globally.ordered(:setup).pass_thru
                flexmock(dev_driver.orocos_task, "dev").should_receive(:start).once.globally.ordered.pass_thru

                expect_execution.scheduler(true).to do
                    emit bus_driver.start_event
                    emit dev_driver.start_event
                end
            end
            assert_equal ["applied configuration [\"default\"] to #{bus_driver.orocos_name}",
                          "setting up #{bus_driver}",
                          "starting #{bus_driver}",
                          "applied configuration [\"default\"] to #{dev_driver.orocos_name}",
                          "setting up #{dev_driver}",
                          "starting #{dev_driver}"], messages
        end

        describe "transaction commit" do
            it "specializes and instanciates dynamic services" do
                srv_m = Syskit::DataService.new_submodel do
                    output_port "out", "/double"
                end
                task_m = Syskit::TaskContext.new_submodel do
                    dynamic_output_port(/.*/, "/double")
                end
                task_m.dynamic_service srv_m, as: "test" do
                    provides srv_m, "out" => name
                end

                plan.add(task = task_m.new)
                plan.in_transaction do |t|
                    proxy = t[task]
                    proxy.require_dynamic_service "test", as: "test"
                    t.commit_transaction
                end
                refute task_m.find_output_port("test")
                assert task.specialized_model?
                assert task.model.find_output_port("test")
            end
        end

        describe "#transaction_modifies_static_ports?" do
            def self.handling_of_static_ports(input: false)
                attr_reader :transaction
                attr_reader :source_task, :sink_task
                before do
                    @source_task = syskit_stub_and_deploy "SourceTask" do
                        p = output_port("out", "int")
                        p.static unless input
                    end
                    @sink_task = syskit_stub_and_deploy "Task" do
                        p = input_port("in", "int")
                        p.static if input
                    end
                    @transaction = create_transaction
                end

                let(:sink_task_p) { transaction[sink_task] }
                let(:source_task_p) { transaction[source_task] }
                let(:task_p) do
                    if input then sink_task_p
                    else source_task_p
                    end
                end

                def configure_tasks
                    syskit_configure(source_task)
                    syskit_configure(sink_task)
                    Runtime::ConnectionManagement.update(plan)
                end

                it "returns true if the transaction adds a connections to a static port" do
                    configure_tasks
                    source_task_p.out_port.connect_to sink_task_p.in_port
                    assert task_p.transaction_modifies_static_ports?
                end
                it "returns false if an unconnected port stays unconnected" do
                    configure_tasks
                    source_task_p # ensure both tasks are in the transaction
                    sink_task_p
                    assert !task_p.transaction_modifies_static_ports?
                end
                it "returns false if a connected port stays the same" do
                    source_task.out_port.connect_to sink_task.in_port
                    configure_tasks
                    source_task_p # ensure both tasks are in the transaction
                    sink_task_p
                    assert !task_p.transaction_modifies_static_ports?
                end
                it "returns true if the transaction removes a connections to a static port" do
                    source_task.out_port.connect_to sink_task.in_port
                    configure_tasks
                    source_task_p.out_port.disconnect_from sink_task_p.in_port
                    assert task_p.transaction_modifies_static_ports?
                end
            end

            describe "handling of static input ports" do
                handling_of_static_ports(input: true)

                it "returns true if a static input port is connected to new tasks" do
                    configure_tasks
                    transaction.add(new_task = source_task.model.new)
                    new_task.out_port.connect_to sink_task_p.in_port
                    assert sink_task_p.transaction_modifies_static_ports?
                end

                it "uses concrete input connections to determine the new connections" do
                    cmp_m = Composition.new_submodel
                    cmp_m.add source_task.model, as: "test"
                    cmp_m.export cmp_m.test_child.out_port, as: "out"
                    cmp = syskit_stub_and_deploy(cmp_m.use("test" => source_task))

                    cmp.out_port.connect_to sink_task.in_port
                    configure_tasks
                    new_cmp = cmp_m.use("test" => source_task_p).instanciate(transaction)
                    cmp_p = transaction[cmp]
                    cmp_p.out_port.disconnect_from sink_task_p.in_port
                    new_cmp.out_port.connect_to sink_task_p.in_port
                    assert !sink_task_p.transaction_modifies_static_ports?
                end
            end
            describe "handling of static output ports" do
                handling_of_static_ports(input: false)

                it "returns true if a static output port is connected to new tasks" do
                    configure_tasks
                    transaction.add(new_task = sink_task.model.new)
                    source_task_p.out_port.connect_to new_task.in_port
                    assert source_task_p.transaction_modifies_static_ports?
                end

                it "uses concrete output connections to determine the new connections" do
                    cmp_m = Composition.new_submodel
                    cmp_m.add sink_task.model, as: "test"
                    cmp_m.export cmp_m.test_child.in_port, as: "in"
                    cmp = syskit_stub_and_deploy(cmp_m.use("test" => sink_task))

                    source_task.out_port.connect_to cmp.in_port
                    configure_tasks
                    new_cmp = cmp_m.use("test" => sink_task_p).instanciate(transaction)
                    transaction[cmp] # wrap in transaction
                    source_task.out_port.disconnect_from cmp.in_port
                    source_task_p.out_port.connect_to new_cmp.in_port
                    assert !source_task_p.transaction_modifies_static_ports?
                end
            end
        end

        describe "specialized models" do
            it "has an isolated orogen model" do
                task_m = TaskContext.new_submodel
                task   = task_m.new
                assert_same task.model.orogen_model, task_m.orogen_model
                task.specialize
                assert_same task.model.orogen_model.superclass, task_m.orogen_model
                task.model.orogen_model.output_port "p", "/double"
                assert !task_m.orogen_model.has_port?("p")
                assert task.model.orogen_model.has_port?("p")
            end
        end

        describe "property handling" do
            attr_reader :double_t, :task_m, :task
            before do
                @double_t = double_t = stub_type "/double"
                @task_m = RubyTaskContext.new_submodel do
                    property "test", double_t
                end
                @task = syskit_deploy(task_m.deployed_as(name, on: "stubs"))
            end

            it "creates all properties at initialization time" do
                assert(p = task.property("test"))
                assert_equal "test", p.name
                assert_same double_t, p.type
            end

            it "initializes the property value(s) using the task's default" do
                syskit_start_execution_agents(@task)
                remote_value = Runkit.allow_blocking_calls { @task.orocos_task.test }

                assert(p = task.property("test"))
                assert_equal remote_value, p.value
                assert_equal remote_value, p.remote_value
            end

            it "disassociates the default value from the property's" do
                task_m = RubyTaskContext.new_submodel do
                    property "test_v", "/std/vector</double>"
                end
                task = syskit_deploy(task_m.deployed_as("#{name}-vector", on: "stubs"))
                syskit_start_execution_agents(task)
                task.properties.test_v << 10

                expect_execution { plan.make_useless(task) }
                    .garbage_collect(true)
                    .to { finalize task }

                task = syskit_deploy(task_m.deployed_as("#{name}-vector", on: "stubs"))
                assert task.property("test_v").value.empty?
                assert task.property("test_v").remote_value.empty?
            end

            it "uses the intermediate type as property type" do
                intermediate_t = stub_type "/intermediate"
                flexmock(Roby.app.default_loader).should_receive(:intermediate_type_for)
                                                 .with(double_t).and_return(intermediate_t)
                task = task_m.new
                assert_same intermediate_t, task.property("test").type
            end

            describe "#has_property?" do
                it "returns true if the property exists" do
                    assert task.has_property?("test")
                end
                it "returns false if the property does not exist" do
                    refute task.has_property?("does_not_exist")
                end
            end

            describe "#property" do
                it "returns the property object" do
                    assert(p = task.property("test"))
                    assert_kind_of Property, p
                    assert_equal task, p.task_context
                    assert_equal "test", p.name
                    assert_same double_t, p.type
                end
                it "accepts a symbol as argument" do # backward compatibility with orocos.rb
                    assert task.property(:test)
                end
                it "raises Runkit::InterfaceObjectNotFound if the property does not exist" do
                    assert_raises(Runkit::InterfaceObjectNotFound) do
                        task.property("does_not_exist")
                    end
                end

                describe "property access through method_missing" do
                    it "returns the property through the _property suffix" do
                        assert_equal task.property("test"), task.test_property
                    end
                    it "raises NoMethodError if the property does not exist" do
                        exception = assert_raises(NoMethodError) do
                            task.does_not_exist_property
                        end
                        assert_match(/^undefined method `does_not_exist_property' for/,
                                     exception.message)
                    end
                    it "passes through to method resolution if the name "\
                        "does not end with _property" do
                        stub_t = stub_type "/test"
                        task_m = TaskContext.new_submodel do
                            output_port "port_test", stub_t
                        end
                        task = task_m.new
                        assert_equal task.find_port("port_test"), task.port_test_port
                    end
                end
            end

            describe "#properties" do
                before do
                    plan.add(task)
                end
                it "gives read/write access to the properties as fields" do
                    task.properties.test = 10
                    assert_equal 10, task.properties.test
                end

                it "gives read/write access to the raw typelib values" do
                    raw_value = Typelib.from_ruby(10, task.test_property.type)
                    task.properties.raw_test = raw_value
                    assert_equal raw_value, task.properties.raw_test
                end

                it "raises NotFound if the property does not exist" do
                    assert_raises(Runkit::NotFound) do
                        task.properties.does_not_exist
                    end
                end
            end

            describe "the property overrides" do
                it "takes precedence over the configuration files" do
                    task = syskit_stub_and_deploy(task_m)
                    task.property_overrides.test = 10
                    flexmock(task.model.configuration_manager).should_receive(:apply)
                                                              .once.and_return { |*args| task.property(:test).write(20) }
                    syskit_configure(task)
                    assert_equal 10, task.property_overrides.test
                end

                it "ensures that #clear_property_overrides can restore the original values" do
                    task = syskit_stub_and_deploy(task_m)
                    task.property_overrides.test = 10
                    flexmock(task.model.configuration_manager).should_receive(:apply)
                                                              .once.and_return { |*args| task.property(:test).write(20) }
                    syskit_configure(task)
                    task.clear_property_overrides
                    assert_equal 20, task.properties.test
                end
            end

            describe "#each_property" do
                it "yields the properties" do
                    recorder = flexmock
                    test_p = task.property("test")
                    recorder.should_receive(:called).with(test_p).once
                    task.each_property { |p| recorder.called(p) }
                end
                it "returns an enumerator if called without a block" do
                    assert_equal [task.property("test")],
                                 task.each_property.to_a
                end
            end

            describe "property updates at runtime" do
                describe "a running task" do
                    attr_reader :task, :property
                    before do
                        @task = syskit_stub_deploy_configure_and_start(task_m)
                        @property = task.test_property
                        Runkit.allow_blocking_calls do
                            @remote_test_property = task.orocos_task.property("test")
                            @remote_test_property.write(0.2)
                        end
                        @property.update_remote_value(0.2)
                    end
                    def mock_remote_property
                        property.remote_property = @remote_test_property
                        flexmock(@remote_test_property)
                    end

                    it "queues a property update" do
                        mock_remote_property.should_receive(:write).once.with(0.1)
                        property.write(0.1)
                        execution_engine.join_all_waiting_work
                    end
                    it "queues only one property update even in case of multiple writes" do
                        mock_remote_property.should_receive(:write).once.with(0.3)
                        property.write(0.1)
                        property.write(0.2)
                        property.write(0.3)
                        execution_engine.join_all_waiting_work
                    end
                    it "does not queue an update on a stopping task" do
                        flexmock(task).should_receive(:commit_properties).never
                        expect_execution { task.stop! }.to { emit task.stop_event }
                        property.write(0.1)
                        execution_engine.join_all_waiting_work
                    end
                    it "does not queue an update on a stopped task" do
                        flexmock(task).should_receive(:commit_properties).never
                        expect_execution { task.stop! }
                            .to { emit task.stop_event }
                        property.write(0.1)
                        execution_engine.join_all_waiting_work
                    end
                    it "reports PropertyUpdateError on a failed write" do
                        error_m = Class.new(RuntimeError)
                        property.write(0.1)
                        mock_remote_property.should_receive(:write).once
                                            .and_raise(error_m)
                        expect_execution.to do
                            have_internal_error task, PropertyUpdateError.match.with_original_exception(error_m)
                        end
                    end
                end

                describe "a non-setup task" do
                    attr_reader :task, :property
                    before do
                        @task = syskit_stub_and_deploy(task_m)
                        syskit_start_execution_agents(task)
                        @property = task.test_property
                        Runkit.allow_blocking_calls do
                            @remote_test_property = task.orocos_task.property("test")
                            @remote_test_property.write(0.2)
                        end
                    end
                    def mock_remote_property
                        property.remote_property = @remote_test_property
                        flexmock(@remote_test_property)
                    end

                    it "does not queue property updates when writing on properties" do
                        flexmock(task).should_receive(:commit_properties).never
                        task.properties.test = 42
                    end

                    it "does commit property changes on setup" do
                        mock_remote_property.should_receive(:write).globally.ordered.pass_thru
                        flexmock(task.orocos_task).should_receive(:configure).globally.ordered.pass_thru
                        task.properties.test = 42
                        syskit_configure(task)
                        assert_equal 42, Runkit.allow_blocking_calls { task.orocos_task.test }
                    end
                end

                describe "a setup but not started task" do
                    attr_reader :task, :property
                    before do
                        @task = syskit_stub_and_deploy(task_m)
                        syskit_start_execution_agents(task)
                        @property = task.test_property
                        Runkit.allow_blocking_calls do
                            @remote_test_property = task.orocos_task.property("test")
                            @remote_test_property.write(0.2)
                        end
                    end

                    def mock_remote_property
                        property.remote_property = @remote_test_property
                        flexmock(@remote_test_property)
                    end

                    describe "property commit" do
                        before do
                            syskit_configure(task)
                        end

                        it "does not queue property updates when writing on properties" do
                            flexmock(task).should_receive(:commit_properties).never
                            task.properties.test = 42
                        end

                        it "does commit property changes on start" do
                            mock_remote_property.should_receive(:write).globally.ordered.pass_thru
                            flexmock(task.orocos_task).should_receive(:start).globally.ordered.pass_thru
                            task.properties.test = 42
                            syskit_start(task)
                            assert_equal 42, Runkit.allow_blocking_calls { task.orocos_task.test }
                        end
                    end

                    describe "reconfiguration on property mismatch" do
                        before do
                            task.properties.test = 42
                            syskit_configure(task)
                            task_name = task.orocos_name
                            plan.add_permanent_task(deployment = task.execution_agent)
                            plan.unmark_mission_task(task)
                            expect_execution.garbage_collect(true).to { finalize task }
                            @task = deployment.task(task_name)
                            task.properties.test = 42
                            flexmock(task.orocos_task)
                        end

                        it "does not reconfigure and keeps the same values if everything is the same" do
                            task.orocos_task.should_receive(:cleanup).never
                            task.orocos_task.should_receive(:configure).never
                            syskit_configure(task)
                            assert_equal 42, Runkit.allow_blocking_calls { task.orocos_task.test }
                        end

                        it "forces a task reconfiguration if the current property value differs from the ones on the task at the point of configuration" do
                            flexmock(task.orocos_task).should_receive(:cleanup)
                                                      .once.globally.ordered.pass_thru
                            flexmock(task.orocos_task).should_receive(:configure)
                                                      .once.globally.ordered.pass_thru
                            task.properties.test = 10
                            syskit_configure(task)
                            assert_equal 10, Runkit.allow_blocking_calls { task.orocos_task.test }
                        end
                        it "forces a task reconfiguration if #configure changes the properties in a way that requires it" do
                            flexmock(task.orocos_task).should_receive(:cleanup)
                                                      .once.globally.ordered.pass_thru
                            flexmock(task.orocos_task).should_receive(:configure)
                                                      .once.globally.ordered.pass_thru
                            def task.configure
                                super
                                properties.test = 10
                            end
                            syskit_configure(task)
                            assert_equal 10, Runkit.allow_blocking_calls { task.orocos_task.test }
                        end
                    end

                    it "does not queue an update on a task that failed-to-start" do
                        flexmock(task).should_receive(:commit_properties).never
                        plan.unmark_mission_task(task)
                        expect_execution { task.start_event.emit_failed }
                            .to { fail_to_start task }
                        property.write(0.1)
                        execution_engine.join_all_waiting_work
                    end
                end
            end

            describe "#commit_properties" do
                attr_reader :task, :stub_property, :remote_test_property
                before do
                    @task = syskit_stub_and_deploy(task_m)
                    syskit_start_execution_agents(task)
                    @stub_property = task.property("test")
                    Runkit.allow_blocking_calls do
                        @remote_test_property = task.orocos_task.property("test")
                        remote_test_property.write(0.2)
                    end
                    @stub_property.update_remote_value(0.2)
                    @guard = syskit_guard_against_start_and_configure
                end
                def mock_remote_property
                    stub_property.remote_property = @remote_test_property
                    flexmock(@remote_test_property)
                end

                it "ignores properties for which #needs_commit? returns false" do
                    flexmock(stub_property).should_receive(:needs_commit?).and_return(false)
                    task.commit_properties.execute
                    flexmock(Runkit::Property).new_instances.should_receive(:write).never
                    execution_engine.join_all_waiting_work
                end

                it "writes the properties that have an explicit value" do
                    stub_property.write(0.1)
                    flexmock(stub_property).should_receive(:needs_commit?).and_return(true)
                    flexmock(Runkit::Property).new_instances.should_receive(:write).once
                                              .with(Typelib.from_ruby(0.1, double_t))
                                              .pass_thru
                    task.commit_properties.execute
                    execution_engine.join_all_waiting_work
                    Runkit.allow_blocking_calls do
                        assert_equal 0.1, remote_test_property.read
                    end
                end
                it "ignores properties whose remote and local values match" do
                    stub_property.update_remote_value(stub_property.value)
                    task.commit_properties.execute
                    flexmock(Runkit::Property).new_instances.should_receive(:write).never
                    execution_engine.join_all_waiting_work
                    Runkit.allow_blocking_calls do
                        assert_equal 0.2, remote_test_property.read
                    end
                end
                it "updates the property's #remote_value after it has been written" do
                    stub_property.write(0.1)
                    property = flexmock
                    property.should_receive(:write).once
                            .globally.ordered
                    stub_property.remote_property = property
                    flexmock(stub_property).should_receive(:update_remote_value).once
                                           .globally.ordered.pass_thru
                    task.commit_properties.execute
                    execution_engine.join_all_waiting_work
                    assert_equal Typelib.from_ruby(0.1, double_t), stub_property.remote_value
                end
                it "updates the property's log after it has been written" do
                    stub_property.write(0.1)
                    mock_remote_property.should_receive(:write).once
                                        .globally.ordered
                    flexmock(stub_property).should_receive(:update_log).once
                                           .globally.ordered.pass_thru
                    task.commit_properties.execute
                    execution_engine.join_all_waiting_work
                end

                it "serializes the executions" do
                    finished = []
                    promises = (0...100).map do |i|
                        promise = task.commit_properties
                        promise.on_success { finished << i }
                        promise
                    end
                    promises.each(&:execute)
                    execution_engine.join_all_waiting_work
                    assert_equal (0...100).to_a, finished.sort
                end

                it "is serialized with the initial commit in task setup" do
                    promises = [
                        task.commit_properties,
                        task.setup,
                        task.commit_properties
                    ]

                    finished = []
                    promises.each_with_index do |p, i|
                        p.before do
                            sleep(0.1 / (i + 1))
                        end
                        p.on_success do
                            Runkit.allow_blocking_calls do
                                assert_equal i, task.orocos_task.test
                            end
                            task.properties.test = i + 1
                            finished << i
                        end
                    end
                    task.properties.test = 0
                    promises.each(&:execute)
                    execution_engine.join_all_waiting_work
                    assert_equal [0, 1, 2], finished
                end

                describe "synchronization of the terminal events and the commit properties promises" do
                    attr_reader :barrier

                    before do
                        execute { plan.remove_free_event(@guard) }
                        @barrier = Concurrent::CyclicBarrier.new(2)
                        syskit_configure_and_start(task)
                        mock_remote_property.should_receive(:write)
                                            .pass_thru { barrier.wait }
                    end

                    def wait_until_promise_stops_on_barrier(barrier = @barrier, &block)
                        expect_execution(&block)
                            .join_all_waiting_work(false)
                            .to { achieve { barrier.number_waiting == 1 } }
                    end

                    it "waits for the last active property commit to finish before emitting the stop event of an interruption" do
                        task.properties.test = 42
                        wait_until_promise_stops_on_barrier
                        expect_execution { task.stop! }.join_all_waiting_work(false).to { achieve { task.orogen_state == :STOPPED } }
                        assert task.finishing?
                        barrier.wait
                        expect_execution.to { emit task.interrupt_event }
                    end

                    it "waits for the last active property commit to finish before emitting a stop event triggered by a state change" do
                        task.properties.test = 42
                        wait_until_promise_stops_on_barrier
                        Runkit.allow_blocking_calls { task.orocos_task.stop }
                        expect_execution.join_all_waiting_work(false).to { achieve { task.finishing? } }
                        barrier.wait
                        expect_execution.to { emit task.success_event }
                    end

                    it "waits for the last active property commit to finish before emitting an exception event" do
                        task.properties.test = 42
                        wait_until_promise_stops_on_barrier
                        Runkit.allow_blocking_calls { task.orocos_task.local_ruby_task.exception }
                        expect_execution.join_all_waiting_work(false).to { achieve { task.finishing? } }
                        barrier.wait
                        expect_execution.to { emit task.exception_event }
                    end

                    it "does not do anything in the property update promise if the "\
                       "task got in the meantime in a state in which it would not use "\
                       "the update" do
                        task.properties.test = 21
                        wait_until_promise_stops_on_barrier
                        barrier.wait
                        expect_execution.to_run
                        assert_equal 21, task.test_property.remote_value

                        flexmock(task).should_receive(:commit_properties).once.pass_thru
                        task.properties.test = 42

                        flexmock(task).should_receive(:would_use_property_update?)
                                      .and_return(false)
                        expect_execution.to_run
                        assert_equal 21, task.test_property.remote_value
                        actual_property_value =
                            Runkit.allow_blocking_calls { task.orocos_task.test }
                        assert_equal 21, actual_property_value
                    end
                end

                describe "the update during setup" do
                    it "reports PropertyUpdateError on a failed write" do
                        error_m = Class.new(RuntimeError)
                        stub_property.write(0.1)
                        mock_remote_property.should_receive(:write).once
                                            .and_raise(error_m)

                        expect_execution { task.commit_properties.execute }
                            .to { have_error_matching PropertyUpdateError.match.with_origin(task).with_original_exception(error_m) }
                    end
                end

                describe "initial values" do
                    attr_reader :task
                    before do
                        task_m = Syskit::TaskContext.new_submodel do
                            property "p", "/int"
                        end
                        flexmock(Runkit::TaskContext)
                            .new_instances
                            .should_receive(:property).with("p")
                            .and_return(
                                flexmock(name: "p", raw_read: 20, log_metadata: {})
                            )
                        @task = syskit_stub_and_deploy(task_m)
                    end

                    it "updates the property's known remote value regardless of the property's current setup" do
                        task.property("p").write(10)
                        task.property("p").update_remote_value(10)
                        syskit_start_execution_agents(task)
                        assert 20, Typelib.to_ruby(task.property("p").remote_value)
                    end

                    it "leaves already set values" do
                        task.property("p").write(10)
                        syskit_start_execution_agents(task)
                        assert 10, Typelib.to_ruby(task.property("p").read)
                    end

                    it "initializes unset properties with the value read from the task" do
                        syskit_start_execution_agents(task)
                        assert 20, Typelib.to_ruby(task.property("p").read)
                    end
                end
            end

            describe "non-blocking characteristics" do
                attr_reader :barrier, :task

                before do
                    @barrier = Concurrent::CyclicBarrier.new(2)
                    @task = syskit_stub_and_deploy(Syskit::TaskContext.new_submodel)
                    syskit_start_execution_agents(task)
                end

                after do
                    barrier.wait(2)
                end

                def wait_for_synchronization(scheduler: false)
                    expect_execution { yield if block_given? }.scheduler(scheduler).join_all_waiting_work(false).to do
                        achieve { barrier.number_waiting == 1 }
                    end
                end

                def assert_process_events_does_not_block
                    expect_execution.join_all_waiting_work(false).to_run
                end

                it "does not block the event loop if the node's configure command blocks" do
                    flexmock(task.orocos_task).should_receive(:configure).once
                                              .pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's start command blocks" do
                    syskit_configure(task)
                    flexmock(task.orocos_task).should_receive(:start).once
                                              .pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization { task.start! }
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's stop command blocks" do
                    syskit_configure_and_start(task)
                    flexmock(task.orocos_task).should_receive(:stop).once
                                              .pass_thru { barrier.wait }
                    plan.unmark_mission_task(task)
                    capture_log(task, :info) do
                        wait_for_synchronization { task.stop! }
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's cleanup command blocks" do
                    Runkit.allow_blocking_calls { task.orocos_task.configure }
                    flexmock(task.orocos_task).should_receive(:cleanup).once
                                              .pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's reset_exception command blocks" do
                    task.orocos_task.local_ruby_task.exception
                    flexmock(task.orocos_task).should_receive(:reset_exception).once
                                              .pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
            end
        end

        describe "deployment shortcuts" do
            before do
                Syskit.conf.register_process_server(
                    "unmanaged_tasks", RobyApp::UnmanagedTasksManager.new
                )

                Roby.app.using_task_library "orogen_syskit_tests"
                @task_m = TaskContext.find_model_from_orogen_name(
                    "orogen_syskit_tests::Empty"
                )
            end
            after do
                Syskit.conf.remove_process_server("unmanaged_tasks")
            end

            it "allows to declare a 'default' deployment" do
                name = "#{Process.pid}#{name}"
                task = syskit_deploy(@task_m.deployed_as(name))
                assert_equal name, task.orocos_name
            end

            it "allows to declare an unmanaged deployment" do
                name = "#{Process.pid}#{name}"
                task = syskit_deploy(@task_m.deployed_as_unmanaged(name))
                assert_equal "unmanaged_tasks", task.execution_agent.arguments[:on]
                assert_equal name, task.orocos_name
            end

            it "allows to use a specific deployment without prefix" do
                task = syskit_deploy(
                    @task_m.deploy_with("syskit_fatal_error_recovery_test")
                )
                assert_equal "b", task.orocos_name
            end

            it "allows to use a specific deployment with prefix" do
                task = syskit_deploy(
                    @task_m.deploy_with("syskit_fatal_error_recovery_test" => Process.pid)
                )
                assert_equal "#{Process.pid}b", task.orocos_name
            end
        end

        describe "read_only" do
            attr_reader :deployment, :handle
            before do
                task_m = TaskContext.new_submodel do
                    property "p", "/double"
                end

                @deployment = syskit_stub_deployment(
                    "test", task_model: task_m, read_only: ["test"]
                )
                expect_execution { deployment.start! }.to { emit deployment.ready_event }

                @handle = deployment.remote_task_handles["test"].handle
            end

            it "emits start when the task is create and started "\
               "while the component is running" do
                Runkit.allow_blocking_calls { handle.configure }
                Runkit.allow_blocking_calls { handle.start }
                create_configure_and_start_task
            end

            it "does not let itself be configured if the component is not configured" do
                assert_raises(Syskit::Test::NetworkManipulation::NoConfigureFixedPoint) do
                    create_and_configure_task
                end
            end

            it "does not let itself be configured if the component is not started" do
                Runkit.allow_blocking_calls { handle.configure }
                assert_raises(Syskit::Test::NetworkManipulation::NoConfigureFixedPoint) do
                    create_and_configure_task
                end
            end

            it "raises when attempting to change a property" do
                Runkit.allow_blocking_calls { handle.configure }
                Runkit.allow_blocking_calls { handle.start }
                task = create_configure_and_start_task

                assert_raises(InvalidReadOnlyOperation) do
                    task.properties.p = 2.0
                end
            end

            it "does not perform setup on configuration" do
                task = deployment.task("test")
                flexmock(task).should_receive(:perform_setup).once.pass_thru
                flexmock(task).should_receive(:prepare_for_setup).never

                Runkit.allow_blocking_calls { handle.configure }
                Runkit.allow_blocking_calls { handle.start }
                syskit_configure(task)
            end

            it "emits start when the task is started while the component is running" do
                Runkit.allow_blocking_calls { handle.configure }
                Runkit.allow_blocking_calls { handle.start }
                create_configure_and_start_task
            end

            describe "stopping behavior" do
                attr_reader :task

                before do
                    Runkit.allow_blocking_calls { handle.configure }
                    Runkit.allow_blocking_calls { handle.start }
                    @task = create_configure_and_start_task
                end

                it "emits stop but not interrupted " \
                   "if the task is stopped while the component is running" do
                    expect_execution { task.stop! }.to do
                        not_emit task.interrupt_event
                        emit task.stop_event
                    end
                end

                it "does not stop the component if the task is stopped" do
                    expect_execution { task.stop! }.to { emit task.stop_event }
                    assert state(handle) == :RUNNING
                end

                it "handles being restarted on the same running component" do
                    task = create_configure_and_start_task
                    expect_execution { task.stop! }.to { emit task.stop_event }
                    task = create_configure_and_start_task
                    expect_execution { task.stop! }.to { emit task.stop_event }
                end
            end

            def create_and_configure_task
                task = @deployment.task("test")
                syskit_configure(task)
                task
            end

            def create_configure_and_start_task
                task = create_and_configure_task
                expect_execution { task.start! }.to { emit task.start_event }
                task
            end

            def state(component)
                Runkit.allow_blocking_calls { component.read_toplevel_state }
            end
        end
    end
end
