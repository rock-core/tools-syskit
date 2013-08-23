require 'syskit/test'

describe Syskit::TaskContext do
    include Syskit::SelfTest

    describe "#initialize" do
        it "sets up the task object to be non-executable" do
            plan.add(task = Syskit::TaskContext.new_submodel.new(:orocos_name => "bla", :conf => []))
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
            plan.add(@deployment1 = deployment_m.new(:on => 'other_host'))
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
            @task = syskit_deploy_task_context 'Task' do
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
            @task = syskit_deploy_task_context 'Task' do
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
            plan.add(@task = task_m.new(:conf => [], :orocos_name => ""))
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
        attr_reader :task, :orocos_task
        before do
            @task = stub_roby_task_context do
                input_port "in", "int"
                output_port "out", "int"
            end
            task.conf = []
            task.executable = true
            @orocos_task = flexmock(task.orocos_task)
        end
        it "disconnects the state readers once emitted" do
            flexmock(task).should_receive(:state_reader).and_return(reader = flexmock)
            reader.should_receive(:disconnect).once
            task.emit :start
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
            plan.add(@task = task_m.new(:conf => [], :orocos_name => ""))
            task.executable = true
            flexmock(task).should_receive(:orocos_task).and_return(@orocos_task = flexmock)
            orocos_task.should_receive(:start).by_default
            orocos_task.should_receive(:exception_state?).by_default
            orocos_task.should_receive(:fatal_error_state?).by_default
            orocos_task.should_receive(:runtime_state?).by_default
            orocos_task.should_receive(:error_state?).by_default
            task.start!
            flexmock(task).should_receive(:emit).with(:start).once.ordered.pass_thru
            flexmock(task).should_receive(:emit).with(:stop).pass_thru
        end

        after do
            if task.start_event.pending?
                task.emit :start
            end
            task.emit :stop if task.running?
        end

        it "does nothing if no runtime state has been received" do
            flexmock(task).should_receive(:orogen_state).and_return(:exception)
            orocos_task.should_receive(:runtime_state?).with(:exception).and_return(false)
            task.handle_state_changes
            assert !task.running?
        end
        it "emits start as soon as a runtime state has been received" do
            flexmock(task).should_receive(:orogen_state).and_return(:blabla)
            orocos_task.should_receive(:runtime_state?).with(:blabla).and_return(true)
            flexmock(task).should_receive(:state_event).with(:blabla).and_return(:success)
            flexmock(task).should_receive(:emit).with(:success).once
            task.handle_state_changes
            assert task.running?
        end
        it "emits the event that is mapped to the state" do
            flexmock(task).should_receive(:orogen_state).and_return(:blabla)
            orocos_task.should_receive(:runtime_state?).with(:blabla).and_return(true)
            flexmock(task).should_receive(:state_event).with(:blabla).and_return(:blabla_event)
            flexmock(task).should_receive(:emit).with(:blabla_event).once.ordered
            task.handle_state_changes
        end
        it "does not emit running if the last state was not an error state" do
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
            it "raises if the state reader got disconnected" do
                state_reader.should_receive(:connected?).and_return(false)
                assert_raises(Syskit::InternalError) { task.update_orogen_state }
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
            @task = flexmock(syskit_deploy_task_context('Task') {})
            task.conf = []
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
            plan.add(@task = Syskit::TaskContext.new_submodel.new(:orocos_name => "", :conf => []))
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
            t0 = task_m.new(:orocos_name => "bla")
            t1 = task_m.new(:orocos_name => "bla")
            t0.needs_reconfiguration!
            assert t1.needs_reconfiguration?
        end
        it "does not set the flag for tasks of the same model but different names" do
            t0 = task_m.new(:orocos_name => "bla")
            t1 = task_m.new(:orocos_name => "other")
            t0.needs_reconfiguration!
            assert !t1.needs_reconfiguration?
        end
    end
    describe "#prepare_for_setup" do
        attr_reader :task, :orocos_task
        before do
            @task = syskit_deploy_task_context 'Task' do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            task.conf = []
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
            Syskit::TaskContext.configured['task'] = [nil, []]
            task.prepare_for_setup(:STOPPED)
        end
        it "returns false if the state is STOPPED and the task does not need to be reconfigured" do
            Syskit::TaskContext.configured['task'] = [nil, []]
            assert !task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task is marked as requiring reconfiguration" do
            flexmock(task).should_receive(:needs_reconfiguration?).and_return(true)
            orocos_task.should_receive(:cleanup).once.pass_thru
            assert task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task has never been configured" do
            Syskit::TaskContext.configured['task'] = nil
            orocos_task.should_receive(:cleanup).once.pass_thru
            assert task.prepare_for_setup(:STOPPED)
        end
        it "cleans up if the state is STOPPED and the task's configuration changed" do
            Syskit::TaskContext.configured['task'] = [nil, ['default']]
            orocos_task.should_receive(:cleanup).once.pass_thru
            assert task.prepare_for_setup(:STOPPED)
        end
    end
    describe "#setup" do
        attr_reader :task, :orocos_task
        before do
            @task = syskit_deploy_task_context 'Task' do
                input_port "in", "int"
                output_port "out", "int"
            end
            task.conf = []
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
            assert_equal [], Syskit::TaskContext.configured['task'][1]
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
            it "calls is_setup!" do
                flexmock(task).should_receive(:is_setup!).once
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
            it "calls is_setup!" do
                flexmock(task).should_receive(:is_setup!).once
                task.setup
            end
            it "still calls the user-provided #configure method" do
                flexmock(task).should_receive(:configure).once
                task.setup
            end
        end
    end
    describe "#configure" do
        attr_reader :task, :orocos_task
        before do
            @task = syskit_deploy_task_context 'Task' do
                input_port "in", "int"
                output_port "out", "int"
            end
            @orocos_task = flexmock(task.orocos_task)
        end
        it "applies the selected configuration" do
            task.conf = ['my', 'conf']
            flexmock(task.model.orogen_model).should_receive(:name).and_return('test::Task')
            flexmock(Orocos.conf).should_receive(:apply).with(orocos_task, ['my', 'conf'], :model_name => 'test::Task', :override => true).once
            task.configure
        end
        it "applies the selected configuration from the parent model on specialized models" do
            flexmock(task.model.orogen_model).should_receive(:name).and_return('test::Task')
            task = syskit_deploy_task_context self.task.model.specialize, 'SpecializedTask'
            task.conf = ['my', 'conf']
            flexmock(Orocos.conf).should_receive(:apply).with(task.orocos_task, ['my', 'conf'], :model_name => 'test::Task', :override => true).once
            task.configure
        end
    end

    describe "interrupt_event" do
        attr_reader :task, :orocos_task, :deployment
        before do
            task_m = Syskit::TaskContext.new_submodel
            @deployment = stub_syskit_deployment('deployment') do
                task "task", task_m.orogen_model
            end
            @task = deployment.task "task"
            task.conf = ['default']

            @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(engine)
        end
        it "calls stop on the task if it has an execution agent in nominal state" do
            plan.add_mission(task)
            deployment.start!
            task.setup
            task.is_setup!
            task.start!
            assert_event_emission task.start_event
            flexmock(task.orocos_task).should_receive(:stop).once.pass_thru
            task.interrupt!
            assert_event_emission task.stop_event
        end
    end

    describe "#deployment_hints" do
        it "should add the hints from its attached devices if there are some" do
            device_hint, component_hint = flexmock, flexmock
            task_m = Syskit::TaskContext.new_submodel
            device_m = Syskit::Device.new_submodel
            task_m.driver_for device_m, :as => 'test'
            dev = robot.device(device_m, :as => 'test').
                use_deployments(device_hint)

            task = task_m.new("test_dev" => dev)
            task.requirements.deployment_hints << component_hint
            assert_equal [component_hint, device_hint].to_set, task.deployment_hints.to_set
        end
    end

    it "should synchronize the startup of communication busses and their supported devices" do
        combus_m = Syskit::ComBus.new_submodel :message_type => '/int'
        combus_driver_m = Syskit::TaskContext.new_submodel do
            dynamic_output_port /.*/, '/int'
        end
        combus_driver_m.provides combus_m, :as => 'driver'
        device_m = Syskit::Device.new_submodel
        device_driver_m = Syskit::TaskContext.new_submodel do
            input_port 'bus_in', '/int'
        end
        device_driver_m.provides combus_m.client_in_srv, :as => 'bus'
        device_driver_m.provides device_m, :as => 'driver'

        bus = robot.com_bus combus_m, :as => 'bus'
        dev = robot.device device_m, :as => 'dev'
        dev.attach_to(bus)

        # Now, deploy !
        stub_syskit_deployment_model(combus_driver_m, 'bus_task')
        stub_syskit_deployment_model(device_driver_m, 'dev_task')
        dev_driver = syskit_run_deployer(dev)
        bus_driver = plan.find_tasks(combus_driver_m).first

        engine.scheduler = nil
        process_events
        dev_driver.execution_agent.start!
        bus_driver.execution_agent.start!

        bus_driver.orocos_task.create_output_port 'dev', '/int'
        flexmock(bus_driver.orocos_task, "bus").should_receive(:start).once.globally.ordered(:setup).pass_thru
        flexmock(bus_driver.orocos_task.dev, "bus.dev").should_receive(:connect_to).once.globally.ordered(:setup).pass_thru
        flexmock(dev_driver.orocos_task, "dev").should_receive(:start).once.globally.ordered.pass_thru

        plan.engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
        process_events
        process_events
    end
end

