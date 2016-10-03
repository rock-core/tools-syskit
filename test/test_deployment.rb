require 'syskit/test/self'

module Syskit
    class ProcessServerFixture
        attr_reader :loader
        attr_reader :tasks
        attr_reader :killed_processes
        def initialize
            @killed_processes = []
            @tasks = Hash.new
            @loader = FlexMock.undefined
        end
        def wait_termination(*)
            @killed_processes, dead_processes = Array.new, @killed_processes
            dead_processes
        end
        def start(name, *)
            tasks.fetch(name)
        end
        def disconnect
        end
    end
    class ProcessFixture
        attr_reader :process_server
        attr_reader :name_mappings
        def initialize(process_server)
            @process_server = process_server
            @name_mappings = Hash['task' => 'mapped_task_name']
        end
        def get_mapped_name(name)
            name_mappings.fetch(name)
        end
        def kill(*args)
            process_server.killed_processes << self
        end
        def resolve_all_tasks(*)
        end
    end

    describe Deployment do
        attr_reader :deployment_task, :task_m, :orogen_deployed_task, :deployment_m
        attr_reader :process_server, :process, :log_dir

        before do
            @task_m = TaskContext.new_submodel
            orogen_model = Orocos::Spec::Deployment.new(Orocos.default_loader, 'deployment')
            @orogen_deployed_task = orogen_model.task 'task', task_m.orogen_model
            @deployment_m = Deployment.new_submodel(orogen_model: orogen_model)

            @process_server = ProcessServerFixture.new
            @process = ProcessFixture.new(process_server)
            process_server.tasks['mapped_task_name'] = process
            @log_dir = flexmock('log_dir')
            Syskit.conf.register_process_server('fixture', process_server, log_dir)
            plan.add_permanent_task(
                @deployment_task = deployment_m.
                new(process_name: 'mapped_task_name', on: 'fixture', name_mappings: Hash['task' => 'mapped_task_name']))

            flexmock(process_server)
            flexmock(process)
            flexmock(deployment_task)
        end
        after do
            if deployment_task.running?
                plan.unmark_permanent_task(deployment_task)
                deployment_task.each_executed_task do |task|
                    plan.unmark_permanent_task(task)
                    plan.unmark_mission_task(task)
                end
            end
        end

        describe "#initialize" do
            it "uses the model name as default deployment name" do
                model = Orocos::Spec::Deployment.new(nil, "test")
                deployment_m = Deployment.new_submodel(orogen_model: model)
                deployment = deployment_m.new
                deployment.freeze_delayed_arguments
                assert_equal "test", deployment.process_name
            end

            it "sets the target host to localhost by default" do
                task = Deployment.new_submodel.new
                task.freeze_delayed_arguments
                assert_equal 'localhost', task.host
            end

            it "allows to access the value of the :on argument through the #host method" do
                task = Deployment.new_submodel.new(on: 'fixture')
                assert_equal 'fixture', task.host
            end
        end

        describe "#pid" do
            it "returns nil when not running" do
                task = Deployment.new_submodel.new
                assert !task.pid
            end
            it "returns orocos_process.pid otherwise" do
                task = Deployment.new_submodel.new
                flexmock(task).should_receive(:running?).and_return(true)
                flexmock(task).should_receive(:orocos_process).and_return(flexmock(pid: (pid = Object.new)))
                assert_same pid, task.pid
            end
        end

        describe "#task" do
            it "raises InvalidState if called while the deployment is finishing" do
                deployment_task.should_receive(:finishing? => true)
                assert_raises(InvalidState) { deployment_task.task 'mapped_task_name' }
            end
            it "raises InvalidState if called while the deployment is finished" do
                deployment_task.should_receive(:finished? => true)
                assert_raises(InvalidState) { deployment_task.task 'mapped_task_name' }
            end
            it "raises ArgumentError if the given activity name is not a task name for this deployment" do
                assert_raises(ArgumentError) { deployment_task.task "does_not_exist" }
            end
            it "returns a new task of the right syskit model" do
                assert_kind_of task_m, deployment_task.task("mapped_task_name")
            end
            it "can create a new task of a specified syskit model" do
                explicit_m = task_m.new_submodel
                assert_kind_of explicit_m, deployment_task.task("mapped_task_name", explicit_m)
            end
            it "raises ArgumentError if the explicit model does not fullfill the expected one" do
                explicit_m = TaskContext.new_submodel
                assert_raises(ArgumentError) { deployment_task.task("mapped_task_name", explicit_m) }
            end
            it "sets orocos_name on the new task" do
                assert_equal 'mapped_task_name', deployment_task.task("mapped_task_name").orocos_name
            end
            it "returns a task with a mapped name using the original name as argument" do
                deployment_task.name_mappings['task'] = 'other_name'
                assert_equal 'other_name', deployment_task.task("other_name").orocos_name
            end
            it "sets orogen_model on the new task" do
                assert_equal orogen_deployed_task, deployment_task.task("mapped_task_name").orogen_model
            end
            it "adds the deployment task as an execution agent for the new task" do
                flexmock(task_m).new_instances.should_receive(:executed_by).with(deployment_task).once
                deployment_task.task("mapped_task_name")
            end
            it "does not do runtime initialization if it is not yet ready" do
                flexmock(Syskit::TaskContext).new_instances.should_receive(:initialize_remote_handles).never
                deployment_task.should_receive(:ready?).and_return(false)
                deployment_task.task("mapped_task_name")
            end
            it "does runtime initialization if it is already ready" do
                task = flexmock(task_m.new)
                flexmock(task_m).should_receive(:new).and_return(task)
                deployment_task.should_receive(:remote_task_handles).
                    and_return('mapped_task_name' => (remote_handles = Object.new))
                task.should_receive(:initialize_remote_handles).with(remote_handles).once
                deployment_task.should_receive(:ready?).and_return(true)
                deployment_task.task("mapped_task_name")
            end
            it "raises InternalError if the name provided as argument matches the model, but task_handles does not contain it" do
                deployment_task.should_receive(:remote_task_handles).
                    and_return('invalid_name' => flexmock)
                deployment_task.should_receive(:ready?).and_return(true)
                assert_raises(InternalError) do
                    deployment_task.task("mapped_task_name")
                end
            end
        end

        describe "runtime behaviour" do
            describe "start_event" do
                it "raises if the process name is set to nil" do
                    plan.add(task = deployment_task.model.new(process_name: nil))
                    e = assert_raises(ArgumentError) do
                        task.start!
                    end
                    assert_equal "must set process_name", e.message
                end
                it "finds the process server from Syskit.process_servers and its on: option" do
                    process_server.should_receive(:start).once.
                        with('mapped_task_name', deployment_m.orogen_model, any, any).
                        and_return(process)
                    deployment_task.start!
                end
                it "passes the process server's log dir as working directory" do
                    process_server.should_receive(:start).once.
                        with(any, any, any, hsh(working_directory: log_dir)).
                        and_return(process)
                    deployment_task.start!
                end
                it "passes the model-level run command line options to the process server start command" do
                    cmdline_options = {valgrind: true}
                    deployment_m.default_run_options.merge!(cmdline_options)
                    process_server.should_receive(:start).
                        with(any, any, any, hsh(cmdline_args: cmdline_options)).
                        and_return(process)
                    deployment_task.start!
                end
                it "raises if the on option refers to a non-existing process server" do
                    plan.add(task = deployment_m.new(on: 'does_not_exist'))
                    assert_raises(Roby::CommandFailed) { task.start! }
                end
                it "does not emit ready" do
                    process_server.should_receive(:start).and_return(process)
                    deployment_task.start!
                    assert !deployment_task.ready?
                end
            end

            describe "monitoring for ready" do
                attr_reader :orocos_task
                before do
                    process_server.should_receive(:start).and_return(process)
                    @orocos_task = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new 'test'
                    end
                end
                after do
                    orocos_task.dispose
                end
                it "does not emit ready if the process is not ready yet" do
                    deployment_task.start!
                    process_events
                    assert !deployment_task.ready?
                end

                def make_deployment_ready
                    process.should_receive(:resolve_all_tasks).
                        and_return('mapped_task_name' => orocos_task)
                    deployment_task.start!
                    process_events
                end

                def add_deployed_task(name: 'mapped_task_name')
                    task_m = Class.new(Roby::Task) do
                        argument :orocos_name
                        attr_accessor :orocos_task
                        terminates
                        def initialize_remote_handles(handles); end
                    end
                    plan.add_permanent_task(task = task_m.new(orocos_name: name))
                    task.executed_by deployment_task
                    flexmock(task)
                end

                it "emits ready when the process is ready" do
                    make_deployment_ready
                    assert deployment_task.ready?
                end
                it "resolves all deployment tasks into task_handles using mapped names" do
                    make_deployment_ready
                    assert_equal orocos_task, deployment_task.remote_task_handles['mapped_task_name'].handle
                end
                it "initializes supported task contexts" do
                    task = add_deployed_task
                    task.should_receive(:initialize_remote_handles).once.
                        with(->(remote) { remote.handle == orocos_task })
                    make_deployment_ready
                end
                it "passes handles already assigned to existing TaskContext to resolve_all_tasks" do
                    task = add_deployed_task
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once.
                        with('mapped_task_name' => orocos_task).
                        and_return('mapped_task_name' => orocos_task)

                    make_deployment_ready
                end
                it "fails if the returned task handle does not match the expectation" do
                    task = add_deployed_task
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once.
                        and_return('invalid_name' => orocos_task)

                    reason = assert_event_becomes_unreachable deployment_task.ready_event do
                        make_deployment_ready
                    end
                    internal_error =
                        (Roby::LocalizedError.match.with_original_exception(InternalError) === reason.context.first)
                    assert_equal "expected #{process}'s reported tasks to include mapped_task_name, but got handles only for invalid_name",
                        internal_error.message
                end
                it "fails an attached TaskContext if its orocos_name does not match the deployment's" do
                    task = add_deployed_task(name: 'invalid_task_name')
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once.
                        and_return('mapped_task_name' => orocos_task)

                    reason = assert_event_becomes_unreachable task.start_event do
                        make_deployment_ready
                    end

                    assert_equal "#{task} is supported by #{deployment_task} but there does not seem to be any task called invalid_task_name on this deployment",
                        reason
                end
            end
            
            describe "stop event" do
                attr_reader :orocos_task
                before do
                    process_server.should_receive(:start).and_return(process)
                    @orocos_task = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new 'test'
                    end
                    flexmock(@orocos_task)
                    process.should_receive(:resolve_all_tasks).
                        and_return('mapped_task_name' => orocos_task)
                    deployment_task.start!
                    assert_event_emission deployment_task.ready_event
                    plan.unmark_permanent_task(deployment_task)
                end
                after do
                    @orocos_task.dispose
                end
                it "cleans up all stopped tasks" do
                    orocos_task.should_receive(:rtt_state).and_return(:STOPPED)
                    orocos_task.should_receive(:cleanup).once
                    deployment_task.stop!
                    execution_engine.join_all_waiting_work(timeout: 2)
                end
                it "marks the task as ready to die" do
                    deployment_task.stop!
                    execution_engine.join_all_waiting_work
                    assert deployment_task.ready_to_die?
                end
                it "kills the process" do
                    process.should_receive(:kill).once.pass_thru
                    deployment_task.stop!
                    assert_event_emission deployment_task.stop_event
                end
                it "ignores com errors with the tasks" do
                    orocos_task.should_receive(:cleanup).and_raise(Orocos::ComError)
                    deployment_task.stop!
                    assert_event_emission deployment_task.stop_event
                end
                it "emits stop if kill fails with a communication error" do
                    process.should_receive(:kill).and_raise(Orocos::ComError)
                    deployment_task.stop!
                    assert_event_emission deployment_task.failed_event
                end
            end

            
        end

        describe "#dead!" do
            attr_reader :process
            it "deregisters all supported task contexts from the TaskContext.configured set" do
                TaskContext.configured['mapped_task_name'] = Object.new
                deployment_task.start!
                plan.unmark_permanent_task(deployment_task)
                deployment_task.dead!(nil)
                assert !TaskContext.configured.include?('mapped_task_name')
            end
            describe "emitted terminal events" do
                before do
                    deployment_m.event :terminal_e, terminal: true
                    plan.clear
                    plan.add_permanent_task(
                        @deployment_task = deployment_m.
                        new(process_name: 'mapped_task_name', on: 'fixture', name_mappings: Hash['task' => 'mapped_task_name']))
                    deployment_task.start!
                    assert_event_emission deployment_task.start_event
                    plan.unmark_permanent_task(deployment_task)
                end

                it "only emits stop if another terminal event was already emitted" do
                    assert_event_emission deployment_task.stop_event, [deployment_task.success_event, deployment_task.failed_event] do
                        deployment_task.dead!(nil)
                    end
                end
                it "emits the failed event if no result was given" do
                    assert_event_emission deployment_task.failed_event, deployment_task.signaled_event do
                        deployment_task.dead!(nil)
                    end
                end
                it "emits the signaled event if the deployment was signaled" do
                    assert_event_emission deployment_task.signaled_event do
                        deployment_task.dead!(flexmock(success?: false, signaled?: true))
                    end
                end
                it "emits the failed event if the deployment was both not succesful and not signaled" do
                    assert_event_emission deployment_task.failed_event, deployment_task.signaled_event do
                        deployment_task.dead!(flexmock(success?: false, signaled?: false))
                    end
                end
                it "emits the success event if the deployment finished normally" do
                    assert_event_emission deployment_task.success_event do
                        deployment_task.dead!(flexmock(success?: true, signaled?: false))
                    end
                end
            end
        end

        describe "#instanciate_all_tasks" do
            it "creates a task for each supported task context" do
                deployment_task.name_mappings['task'] = 'mapped_task_name'
                deployment_task.should_receive(:task).with('mapped_task_name').once
                deployment_task.instanciate_all_tasks
            end
        end

        describe "using the ruby process server" do
            attr_reader :task_m, :deployment_m, :deployment
            before do
                Syskit.conf.register_process_server('test', Orocos::RubyTasks::ProcessManager.new, "")
                task_m = @task_m = TaskContext.new_submodel do
                    input_port 'in', '/double'
                    output_port 'out', '/double'
                end
                @deployment_m = Deployment.new_submodel(name: 'deployment') do
                    task 'task', task_m.orogen_model
                end
                Syskit.conf.process_server_for('test').
                    register_deployment_model(deployment_m.orogen_model)
                plan.add_permanent_task(@deployment = deployment_m.new(on: 'test'))
                deployment.start!
                assert_event_emission deployment.ready_event
            end
            it "can start tasks defined on a ruby process server" do
                task = deployment.task('task')
                assert task.orocos_task
                assert 'task', task.orocos_task.name
            end
            it "sets the orocos_task attribute to a RubyTaskContext" do
                assert_kind_of Orocos::RubyTasks::TaskContext, deployment.task('task').orocos_task
            end
            it "makes sure that the Ruby tasks are disposed when the deployment is stopped" do
                flexmock(deployment.task('task').orocos_task).should_receive(:dispose).once.pass_thru
                deployment.stop!
                assert_event_emission deployment.stop_event
            end
        end
    end
end

