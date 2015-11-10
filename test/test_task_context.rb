require 'syskit/test/self'

describe Syskit::TaskContext do
    describe "#initialize" do
        it "sets up the task object to be non-executable" do
            plan.add(task = Syskit::TaskContext.new_submodel.new(orocos_name: "bla", conf: []))
            assert !task.executable?
            # Verify that the task is indeed non-executable because the flag is
            # already set
            task.executable = nil
            assert task.executable?
        end
    end

    describe "#can_merge?" do
        attr_reader :merging_task, :merged_task
        before do
            task_m = Syskit::TaskContext.new_submodel
            @merging_task = task_m.new
            @merged_task  = task_m.new
        end
        it "returns true for the same tasks" do
            assert merging_task.can_merge?(merged_task)
        end
        it "returns true if only one of the two tasks have a required host" do
            merging_task.required_host = 'host'
            assert merging_task.can_merge?(merged_task)
            assert merged_task.can_merge?(merging_task)
        end
        it "returns true if both tasks have a required host and it is identical" do
            merging_task.required_host = 'host'
            merged_task.required_host = 'host'
            assert merging_task.can_merge?(merged_task)
        end
        it "returns false if both tasks have a required host and it differs" do
            merging_task.required_host = 'host'
            merged_task.required_host = 'other_host'
            assert !merging_task.can_merge?(merged_task)
        end
    end

    describe "#distance_to" do
        attr_reader :task0, :task1
        attr_reader :deployment_m, :deployment0, :deployment1
        before do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(@task0 = task_m.new)
            plan.add(@task1 = task_m.new)
            @deployment_m = Syskit::Deployment.new_submodel
            plan.add(@deployment0 = deployment_m.new)
            plan.add(@deployment1 = deployment_m.new)
        end
        it "returns D_SAME_PROCESS if both tasks are from the same process" do
            task0.executed_by deployment0
            task1.executed_by deployment0
            assert_equal Syskit::TaskContext::D_SAME_PROCESS, task0.distance_to(task1)
        end
        it "returns D_SAME_HOST if both tasks are from processes on the same host" do
            task0.executed_by deployment0
            task1.executed_by deployment1
            assert_equal Syskit::TaskContext::D_SAME_HOST, task0.distance_to(task1)
        end
        it "returns D_DIFFERENT_HOSTS if both tasks are from processes from different hosts" do
            plan.add(@deployment1 = deployment_m.new(on: 'other_host'))
            task0.executed_by deployment0
            task1.executed_by deployment1
            assert_equal Syskit::TaskContext::D_DIFFERENT_HOSTS, task0.distance_to(task1)
        end
        it "returns nil if one of the two tasks has no execution agent" do
            plan.add(task = Syskit::TaskContext.new_submodel.new)
            assert !task.distance_to(task0)
            assert !task0.distance_to(task)
        end
    end

    describe "#find_input_port" do
        attr_reader :task
        before do
            @task = syskit_stub_deploy_and_configure 'Task' do
                input_port "in", "int"
                output_port "out", "int"
            end
        end

        it "should return the port from #orocos_task if it exists" do
            assert_equal task.orocos_task.port("in"), task.find_input_port("in").to_orocos_port
        end
        it "should return nil for an output port" do
            assert_equal nil, task.find_input_port("out")
        end
        it "should return nil for a port that does not exist" do
            assert_equal nil, task.find_input_port("does_not_exist")
        end
    end

    describe "#find_output_port" do
        attr_reader :task
        before do
            @task = syskit_stub_deploy_and_configure 'Task' do
                input_port "in", "int"
                output_port "out", "int"
            end
        end

        it "should return the port from #orocos_task if it exists" do
            assert_equal task.orocos_task.port("out"), task.find_output_port("out").to_orocos_port
        end
        it "should return nil for an input port" do
            assert_equal nil, task.find_output_port("in")
        end
        it "should return nil for a port that does not exist" do
            assert_equal nil, task.find_output_port("does_not_exist")
        end
    end

    describe "start_event" do
        attr_reader :task, :task_m, :orocos_task
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            plan.add(@task = task_m.new(conf: [], orocos_name: ""))
            task.executable = true
            flexmock(task).should_receive(:orocos_task).and_return(@orocos_task = flexmock)
        end

        after do
            if task.start_event.pending?
                task.emit :start
            end
            task.emit :stop if task.running?
        end

        it "should start the underlying task" do
            orocos_task.should_receive(:start).once
            task.start!
        end

        it "should check that all required output ports are present" do
            flexmock(task).should_receive(:each_concrete_output_connection).and_yield(port = Object.new)
            orocos_task.should_receive(:has_port?).once.
                with(port).and_return(true)
            orocos_task.should_receive(:start)
            task.start!
        end
        it "should raise Orocos::NotFound if some required output ports are not present" do
            flexmock(task).should_receive(:each_concrete_output_connection).and_yield(port = Object.new)
            orocos_task.should_receive(:has_port?).once.
                with(port).and_return(false)
            orocos_task.should_receive(:start).never
            assert_event_command_failed(Orocos::NotFound) { task.start! }
        end
        it "should check that all required input ports are present" do
            flexmock(task).should_receive(:each_concrete_input_connection).and_yield(nil, nil, port = Object.new, nil)
            orocos_task.should_receive(:has_port?).once.
                with(port).and_return(true)
            orocos_task.should_receive(:start)
            task.start!
        end
        it "should raise Orocos::NotFound if some required input ports are not present" do
            flexmock(task).should_receive(:each_concrete_input_connection).and_yield(nil, nil, port = Object.new, nil)
            orocos_task.should_receive(:has_port?).once.
                with(port).and_return(false)
            orocos_task.should_receive(:start).never
            assert_event_command_failed(Orocos::NotFound) { task.start! }
        end
        it "does not emit the start event" do
            orocos_task.should_receive(:start).once
            task.start!
            assert !task.running?
        end
    end

    describe "#state_event" do
        it "should be able to resolve events from parent models" do
            parent_m = Syskit::TaskContext.new_submodel do
                runtime_states :CUSTOM
            end
            child_m = parent_m.new_submodel
            child = child_m.new
            assert_equal :custom, child.state_event(:CUSTOM)
        end
    end

    describe "stop_event" do
        it "disconnects the state readers once emitted" do
            task = syskit_stub_deploy_configure_and_start(Syskit::TaskContext.new_submodel)
            task.create_state_reader
            flexmock(task.state_reader).should_receive(:disconnect).once
            task.emit :stop
        end
    end

    describe "#handle_state_change" do
        attr_reader :task, :task_m, :orocos_task
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            @task = syskit_stub_deploy_and_configure(task_m)
            @orocos_task = flexmock(task.orocos_task)
            orocos_task.should_receive(:start).by_default
            orocos_task.should_receive(:exception_state?).by_default
            orocos_task.should_receive(:fatal_error_state?).by_default
            orocos_task.should_receive(:runtime_state?).by_default
            orocos_task.should_receive(:error_state?).by_default
            flexmock(task).should_receive(:emit).with(:stop).pass_thru
            task.start!
        end

        after do
            if task.start_event.pending?
                task.emit :start
            end
            task.emit :stop if task.running?
        end

        it "does nothing if no runtime state has been received" do
            flexmock(task).should_receive(:emit).with(:start).never
            flexmock(task).should_receive(:orogen_state).and_return(:exception)
            orocos_task.should_receive(:runtime_state?).with(:exception).and_return(false)
            task.handle_state_changes
            assert !task.running?
        end
        it "emits start as soon as a runtime state has been received" do
            flexmock(task).should_receive(:emit).with(:start).once.pass_thru
            flexmock(task).should_receive(:orogen_state).and_return(:blabla)
            orocos_task.should_receive(:runtime_state?).with(:blabla).and_return(true)
            flexmock(task).should_receive(:state_event).with(:blabla).and_return(:success)
            flexmock(task).should_receive(:emit).with(:success).once
            task.handle_state_changes
            assert task.running?
        end
        it "emits the event that is mapped to the state" do
            flexmock(task).should_receive(:emit).with(:start).once.pass_thru
            flexmock(task).should_receive(:orogen_state).and_return(:blabla)
            orocos_task.should_receive(:runtime_state?).with(:blabla).and_return(true)
            flexmock(task).should_receive(:state_event).with(:blabla).and_return(:blabla_event)
            flexmock(task).should_receive(:emit).with(:blabla_event).once.ordered
            task.handle_state_changes
        end
        it "does not emit running if the last state was not an error state" do
            flexmock(task).should_receive(:emit).with(:start).once.pass_thru
            orocos_task.should_receive(:runtime_state?).with(:RUNNING).and_return(true)
            flexmock(task).should_receive(:orogen_state).and_return(:RUNNING)
            flexmock(task).should_receive(:last_orogen_state).and_return(:BLA)
            orocos_task.should_receive(:error_state?).with(:BLA).once.and_return(false)
            flexmock(task).should_receive(:emit).with(:running).never
            task.handle_state_changes
        end
    end

    describe "#update_orogen_state" do
        attr_reader :task, :orocos_task
        before do
            task_m = Syskit::TaskContext.new_submodel
            @task = flexmock(task_m.new)
            @orocos_task = flexmock
            task.should_receive(:orocos_task).and_return(orocos_task)
            orocos_task.should_receive(:rtt_state).by_default
        end

        describe "the task has extended state support" do
            attr_reader :state_reader
            before do
                task.model.orogen_model.extended_state_support
                @state_reader = flexmock
                state_reader.should_receive(:connected?).and_return(true).by_default
                state_reader.should_receive(:read_new).by_default
                flexmock(task).should_receive(:state_reader).and_return(state_reader).by_default
            end

            it "creates a state reader if one is not set yet" do
                task.should_receive(:create_state_reader).once
                task.should_receive(:state_reader).and_return(nil)
                task.update_orogen_state
            end
            it "does not create a state reader if one has already been set" do
                task.should_receive(:create_state_reader).never
                task.update_orogen_state
            end
            it "emits :aborted if the state reader got disconnected" do
                task = syskit_stub_deploy_configure_and_start('Task')
                task.update_orogen_state
                task.state_reader.disconnect
                orocos_task = task.orocos_task
                assert_raises(Roby::MissionFailedError) { task.update_orogen_state }
                assert task.aborted_event.happened?
                assert_equal :STOPPED, orocos_task.rtt_state
            end
            it "sets orogen_state with the new state" do
                state_reader.should_receive(:read_new).and_return(state = Object.new)
                task.update_orogen_state
                assert_equal state, task.orogen_state
            end
            it "updates last_orogen_state with the current state" do
                state_reader.should_receive(:read_new).and_return(state = Object.new)
                task.should_receive(:orogen_state).and_return(last_state = Object.new)
                task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
            end
            it "returns nil if no new state has been received" do
                assert !task.update_orogen_state
            end
            it "does not change the last and current states if no new states have been received" do
                state_reader.should_receive(:read_new).
                    and_return(last_state = Object.new).
                    and_return(state = Object.new).
                    and_return(nil)
                task.update_orogen_state
                task.update_orogen_state
                assert !task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
                assert_equal state, task.orogen_state
            end
            it "returns the new state if there is one" do
                state_reader.should_receive(:read_new).and_return(state = Object.new)
                assert_equal state, task.update_orogen_state
            end
        end

        describe "the task does not have extended state support" do
            it "does not create a state reader" do
                task.should_receive(:create_state_reader).never
                task.update_orogen_state
            end
            it "sets orogen_state with the new state" do
                orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
                task.update_orogen_state
                assert_equal state, task.orogen_state
            end
            it "updates last_orogen_state with the current state" do
                orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
                task.should_receive(:orogen_state).and_return(last_state = Object.new)
                task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
            end
            it "returns nil if no new state has been received" do
                assert !task.update_orogen_state
            end
            it "does not change the last and current states if no new states have been received" do
                orocos_task.should_receive(:rtt_state).
                    and_return(last_state = Object.new).
                    and_return(state = Object.new).
                    and_return(state)
                task.update_orogen_state
                task.update_orogen_state
                assert !task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
                assert_equal state, task.orogen_state
            end
            it "returns the new state if there is one" do
                orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
                assert_equal state, task.update_orogen_state
            end
        end
    end
    describe "#ready_for_setup?" do
        attr_reader :task, :orocos_task
        before do
            @task = flexmock(syskit_stub_deploy_and_configure('Task') {})
            @orocos_task = flexmock
            task.should_receive(:orocos_task).and_return(orocos_task)
            orocos_task.should_receive(:rtt_state).by_default
        end

        it "returns false if task arguments are not set" do
            orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
            flexmock(Syskit::TaskContext::RTT_CONFIGURABLE_STATES).should_receive(:include?).
                with(state).and_return(true)
            assert task.ready_for_setup?
            task.should_receive(:fully_instanciated?).and_return(false)
            assert !task.ready_for_setup?
        end
        it "returns false if the task has no orogen model yet" do
            task.should_receive(:orogen_model)
            assert !task.ready_for_setup?
        end
        it "returns false if the task has no orocos task yet" do
            task.should_receive(:orocos_task)
            assert !task.ready_for_setup?
        end
        it "returns false if the task's current state cannot be read" do
            orocos_task.should_receive(:rtt_state).once.and_raise(Orocos::ComError)
            assert !task.ready_for_setup?
        end
        it "returns false if the task's current state is not one from which we can configure" do
            orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
            flexmock(Syskit::TaskContext::RTT_CONFIGURABLE_STATES).should_receive(:include?).once.
                with(state).and_return(false)
            assert !task.ready_for_setup?
        end
        it "returns true if the task's current state is one from which we can configure" do
            orocos_task.should_receive(:rtt_state).and_return(state = Object.new)
            flexmock(Syskit::TaskContext::RTT_CONFIGURABLE_STATES).should_receive(:include?).once.
                with(state).and_return(true)
            assert task.ready_for_setup?
        end
    end
    describe "#is_setup!" do
        attr_reader :task
        before do
            plan.add(@task = Syskit::TaskContext.new_submodel.new(orocos_name: "", conf: []))
            assert !task.executable?
        end
        it "resets the executable flag if all inputs are connected" do
            flexmock(task).should_receive(:all_inputs_connected?).and_return(true).once
            task.is_setup!
            assert task.executable?
        end
        it "does not reset the executable flag if some inputs are not connected" do
            flexmock(task).should_receive(:all_inputs_connected?).and_return(false).once
            task.is_setup!
            assert !task.executable?
        end
    end
    describe "#reusable?" do
        it "is false if the task is setup and needs reconfiguration" do
            task = Syskit::TaskContext.new_submodel.new
            assert task.reusable?
            flexmock(task).should_receive(:setup?).and_return(true)
            flexmock(task).should_receive(:needs_reconfiguration?).and_return(true)
            assert !task.reusable?
        end
    end
    describe "needs_reconfiguration" do
        attr_reader :task_m
        before do
            @task_m = Syskit::TaskContext.new_submodel
        end
        it "sets the reconfiguration flag to true for a given orocos name" do
            t0 = task_m.new(orocos_name: "bla")
            t1 = task_m.new(orocos_name: "bla")
            t0.needs_reconfiguration!
            assert t1.needs_reconfiguration?
        end
        it "does not set the flag for tasks of the same model but different names" do
            t0 = task_m.new(orocos_name: "bla")
            t1 = task_m.new(orocos_name: "other")
            t0.needs_reconfiguration!
            assert !t1.needs_reconfiguration?
        end
    end
    describe "#prepare_for_setup" do
        attr_reader :task, :orocos_task
        before do
            task_m = Syskit::TaskContext.new_submodel
            @task = syskit_stub_deploy_and_configure(task_m, as: 'task')
            @orocos_task = flexmock(task.orocos_task)
        end

        it "resets an exception state and calls prepare_for_setup back without arguments" do
            orocos_task.should_receive(:reset_exception).once.ordered
            flexmock(task).should_receive(:prepare_for_setup).with(:EXCEPTION).once.ordered.pass_thru
            flexmock(task).should_receive(:prepare_for_setup).with().once.ordered.and_return(ret = Object.new)
            assert_same ret, task.prepare_for_setup(:EXCEPTION)
        end
        it "does nothing if the state is PRE_OPERATIONAL" do
            task.prepare_for_setup(:PRE_OPERATIONAL)
        end
        it "returns true if the state is PRE_OPERATIONAL" do
            assert task.prepare_for_setup(:PRE_OPERATIONAL)
        end
        it "does nothing if the state is STOPPED and the task does not need to be reconfigured" do
            Syskit::TaskContext.configured['task'] = [nil, ['default'], Set.new]
            task.prepare_for_setup(:STOPPED)
        end
        it "returns false if the state is STOPPED and the task does not need to be reconfigured" do
            Syskit::TaskContext.configured['task'] = [nil, ['default'], Set.new]
            assert !task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task is marked as requiring reconfiguration" do
            flexmock(task).should_receive(:needs_reconfiguration?).and_return(true)
            orocos_task.should_receive(:cleanup).once
            assert task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task has never been configured" do
            Syskit::TaskContext.configured['task'] = nil
            orocos_task.should_receive(:cleanup).once
            assert task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task's configuration changed" do
            Syskit::TaskContext.configured['task'] = [nil, [], Set.new]
            orocos_task.should_receive(:cleanup).once
            assert task.prepare_for_setup(:STOPPED)
        end
        describe "handling of dynamic input ports" do
            it "removes the connections to dynamic input ports from ActualDataFlow" do
                srv_m = Syskit::DataService.new_submodel { input_port 'p', '/double' }
                task_m = Syskit::TaskContext.new_submodel do
                    orogen_model.dynamic_input_port /.*/, '/double'
                end
                task_m.dynamic_service srv_m, as: 'test' do
                    provides srv_m, 'p' => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service 'test', as: 'test'
                source_task = syskit_stub_deploy_and_configure 'SourceTask', as: 'source_task' do
                    input_port "dynamic", "/double"
                end
                orocos_tasks = [source_task.orocos_task, task.orocos_task]

                Syskit::ActualDataFlow.add_connections(*orocos_tasks, Hash[['dynamic', 'dynamic'] => [Hash.new, false, false]])
                assert Syskit::ActualDataFlow.linked?(*orocos_tasks)

                Syskit::TaskContext.configured['task'] = nil
                flexmock(task.orocos_task).should_receive(:cleanup).once
                assert task.prepare_for_setup(:STOPPED)
                assert !Syskit::ActualDataFlow.linked?(*orocos_tasks)
            end
        end
        describe "handling of dynamic output ports" do
            it "removes the connections to dynamic output ports from ActualDataFlow" do
                srv_m = Syskit::DataService.new_submodel { output_port 'p', '/double' }
                task_m = Syskit::TaskContext.new_submodel do
                    orogen_model.dynamic_output_port /.*/, '/double'
                end
                task_m.dynamic_service srv_m, as: 'test' do
                    provides srv_m, 'p' => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service 'test', as: 'test'

                sink_task = syskit_stub_deploy_and_configure 'SinkTask', as: 'sink_task' do
                    output_port "dynamic", "/double"
                end
                orocos_tasks = [task.orocos_task, sink_task.orocos_task]

                Syskit::ActualDataFlow.add_connections(*orocos_tasks, Hash[['dynamic', 'dynamic'] => [Hash.new, false, false]])
                assert Syskit::ActualDataFlow.linked?(*orocos_tasks)

                Syskit::TaskContext.configured['task'] = nil
                flexmock(task.orocos_task).should_receive(:cleanup).once
                assert task.prepare_for_setup(:STOPPED)
                assert !Syskit::ActualDataFlow.linked?(*orocos_tasks)
            end
        end
    end
    describe "#setup" do
        attr_reader :task, :orocos_task
        before do
            @task = syskit_stub_and_deploy 'Task', as: 'task' do
                input_port "in", "int"
                output_port "out", "int"
            end
            syskit_start_execution_agents(task, recursive: true)
            @orocos_task = flexmock(task.orocos_task)
            flexmock(task).should_receive(:ready_for_setup?).with(:BLA).and_return(true).by_default
            orocos_task.should_receive(:rtt_state).by_default.and_return(:BLA)
        end

        it "calls rtt_state only once" do
            orocos_task.should_receive(:rtt_state).once.and_return(:PRE_OPERATIONAL)
            flexmock(task).should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
            task.setup
        end
        it "raises if the task is not ready for setup" do
            flexmock(task).should_receive(:ready_for_setup?).with(:BLA).and_return(false)
            assert_raises(Syskit::InternalError) do
                task.setup
            end
        end
        it "resets the needs_configuration flag" do
            orocos_task.should_receive(:rtt_state).once.and_return(:PRE_OPERATIONAL)
            flexmock(task).should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
            task.needs_reconfiguration!
            task.setup
            assert !task.needs_reconfiguration?
        end
        it "registers the current task configuration" do
            orocos_task.should_receive(:rtt_state).once.and_return(:PRE_OPERATIONAL)
            flexmock(task).should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
            task.needs_reconfiguration!
            task.setup
            assert_equal ['default'], Syskit::TaskContext.configured['task'][1]
        end
        it "calls the user-provided #configure method after prepare_for_setup" do
            flexmock(task).should_receive(:prepare_for_setup).once.
                with(:BLA).and_return(true).ordered
            flexmock(task).should_receive(:configure).once.ordered
            task.setup
        end

        describe "prepare_for_setup returns true" do
            before do
                flexmock(task).should_receive(:prepare_for_setup).once.
                    with(:BLA).and_return(true)
            end
            it "configures the task" do
                orocos_task.should_receive(:configure).once
                task.setup
            end
            it "does not call is_setup!" do
                flexmock(task).should_receive(:is_setup!).never
                task.setup
            end
            it "calls the user-provided #configure method" do
                flexmock(task).should_receive(:configure).once
                task.setup
            end
            it "does not call is_setup! if the task's configure method fails" do
                orocos_task.should_receive(:configure).and_raise(ArgumentError)
                flexmock(task).should_receive(:is_setup!).never
                assert_raises(ArgumentError) { task.setup }
            end
            it "does not call is_setup! if the user-provided configure method raises" do
                flexmock(task).should_receive(:configure).and_raise(ArgumentError)
                flexmock(task).should_receive(:is_setup!).never
                assert_raises(ArgumentError) { task.setup }
            end
        end
        describe "prepare_for_setup returns false" do
            before do
                flexmock(task).should_receive(:prepare_for_setup).once.
                    with(:BLA).and_return(false)
            end
            it "does not configure the task" do
                orocos_task.should_receive(:configure).never
                task.setup
            end
            it "does not call is_setup!" do
                flexmock(task).should_receive(:is_setup!).never
                task.setup
            end
            it "still calls the user-provided #configure method" do
                flexmock(task).should_receive(:configure).once
                task.setup
            end
        end
    end
    describe "#configure" do
        it "applies the selected configuration" do
            task_m = Syskit::TaskContext.new_submodel name: 'Task' do
                property 'v', '/int'
            end
            task = syskit_stub_and_deploy(task_m.with_conf('my', 'conf'))
            flexmock(task.model.configuration_manager).should_receive(:conf).
                with(['my', 'conf'], true).
                once.
                and_return('v' => 10)
            syskit_configure(task)
            assert_equal 10, task.orocos_task.v
        end
    end

    describe "interrupt_event" do
        attr_reader :task, :orocos_task, :deployment
        it "calls stop on the task if it has an execution agent in nominal state" do
            task = syskit_stub_deploy_configure_and_start(Syskit::TaskContext.new_submodel)
            flexmock(task.orocos_task).should_receive(:stop).once.pass_thru
            task.interrupt!
            assert_event_emission task.stop_event
        end
    end

    describe "#deployment_hints" do
        describe "the behaviour for device drivers" do
            let(:component_hint) { flexmock }
            let(:device_hint) { flexmock }
            let(:task) do
                device_m = Syskit::Device.new_submodel
                task_m = Syskit::TaskContext.new_submodel
                task_m.driver_for device_m, as: 'test'
                dev = robot.device(device_m, as: 'test').prefer_deployed_tasks(device_hint)
                task_m.new("test_dev" => dev)
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

    describe "#transaction_modifies_static_ports?" do
        def self.handling_of_static_ports(input: false)
            attr_reader :transaction
            attr_reader :source_task, :sink_task
            before do
                @source_task = syskit_stub_and_deploy "SourceTask", as: 'source_task' do
                    p = output_port('out', 'int')
                    p.static if !input
                end
                @sink_task = syskit_stub_and_deploy "Task" do
                    p = input_port('in', 'int')
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
                Syskit::Runtime::ConnectionManagement.update(plan)
            end

            it "returns true if the transaction adds a connections to a static port" do
                configure_tasks
                source_task_p.out_port.connect_to sink_task_p.in_port
                assert task_p.transaction_modifies_static_ports?
            end
            it "returns false if an unconnected port stays unconnected" do
                configure_tasks
                source_task_p; sink_task_p # ensure both tasks are in the transaction
                assert !task_p.transaction_modifies_static_ports?
            end
            it "returns false if a connected port stays the same" do
                source_task.out_port.connect_to sink_task.in_port
                configure_tasks
                source_task_p; sink_task_p # ensure both tasks are in the transaction
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
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add source_task.model, as: 'test'
                cmp_m.export cmp_m.test_child.out_port, as: 'out'
                cmp = syskit_stub_and_deploy(cmp_m.use('test' => source_task))

                cmp.out_port.connect_to sink_task.in_port
                configure_tasks
                new_cmp = cmp_m.use('test' => source_task_p).instanciate(transaction)
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
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add sink_task.model, as: 'test'
                cmp_m.export cmp_m.test_child.in_port, as: 'in'
                cmp = syskit_stub_and_deploy(cmp_m.use('test' => sink_task))

                source_task.out_port.connect_to cmp.in_port
                configure_tasks
                new_cmp = cmp_m.use('test' => sink_task_p).instanciate(transaction)
                cmp_p = transaction[cmp]
                source_task.out_port.disconnect_from cmp.in_port
                source_task_p.out_port.connect_to new_cmp.in_port
                assert !source_task_p.transaction_modifies_static_ports?
            end
        end
    end

    describe "specialized models" do
        it "has an isolated orogen model" do
            task_m = Syskit::TaskContext.new_submodel
            task   = task_m.new
            assert_same task.model.orogen_model, task_m.orogen_model
            task.specialize
            assert_same task.model.orogen_model.superclass, task_m.orogen_model
            task.model.orogen_model.output_port 'p', '/double'
            assert !task_m.orogen_model.has_port?('p')
            assert task.model.orogen_model.has_port?('p')
        end
    end
end

