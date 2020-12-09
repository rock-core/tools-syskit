# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    class ProcessServerFixture
        attr_reader :loader
        attr_reader :tasks
        attr_reader :killed_processes
        def initialize
            @killed_processes = []
            @tasks = {}
            @loader = FlexMock.undefined
        end

        def wait_termination(*)
            dead_processes = @killed_processes
            @killed_processes = []
            dead_processes
        end

        def start(name, *)
            tasks.fetch(name)
        end

        def disconnect; end
    end
    class ProcessFixture
        attr_reader :process_server
        attr_reader :name_mappings
        def initialize(process_server)
            @process_server = process_server
            @name_mappings = Hash["task" => "mapped_task_name"]
        end

        def get_mapped_name(name)
            name_mappings.fetch(name)
        end

        def kill(*, **)
            process_server.killed_processes << self
        end

        def resolve_all_tasks(*); end
    end

    describe Deployment do
        attr_reader :deployment_task, :task_m, :orogen_deployed_task, :deployment_m
        attr_reader :process_server, :process_server_config, :process, :log_dir

        before do
            @task_m = TaskContext.new_submodel
            orogen_model = Orocos::Spec::Deployment.new(Orocos.default_loader, "deployment")
            @orogen_deployed_task = orogen_model.task "task", task_m.orogen_model
            @deployment_m = Deployment.new_submodel(orogen_model: orogen_model)

            @process_server = ProcessServerFixture.new
            @process = ProcessFixture.new(process_server)
            process_server.tasks["mapped_task_name"] = process
            @log_dir = flexmock("log_dir")
            @process_server_config = Syskit.conf.register_process_server("fixture", process_server, log_dir)
            plan.add_permanent_task(
                @deployment_task = deployment_m
                .new(process_name: "mapped_task_name", on: "fixture", name_mappings: Hash["task" => "mapped_task_name"])
            )

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

        # Helper method that mocks a port accessed through
        # Orocos::TaskContext#raw_port
        def mock_raw_port(task, port_name)
            if task.respond_to?(:orocos_task)
                task = task.orocos_task
            end

            port = Orocos.allow_blocking_calls do
                task.raw_port(port_name)
            end
            task.should_receive(:raw_port).with(port_name).and_return(port)
            flexmock(port)
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
                assert_equal "localhost", task.process_server_name
            end

            it "allows to access the value of the :on argument through the #process_server_name method" do
                task = Deployment.new_submodel.new(on: "fixture")
                assert_equal "fixture", task.process_server_name
            end

            it "allows to access the process server's host_id through #host_id" do
                task = Deployment.new_submodel.new(on: "fixture")
                flexmock(process_server_config).should_receive(:host_id).and_return(host_id = flexmock)
                assert_equal host_id, task.host_id
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
                assert_raises(InvalidState) { deployment_task.task "mapped_task_name" }
            end
            it "raises InvalidState if called while the deployment is finished" do
                deployment_task.should_receive(:finished? => true)
                assert_raises(InvalidState) { deployment_task.task "mapped_task_name" }
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
                assert_equal "mapped_task_name", deployment_task.task("mapped_task_name").orocos_name
            end
            it "returns a task with a mapped name using the original name as argument" do
                deployment_task.name_mappings["task"] = "other_name"
                assert_equal "other_name", deployment_task.task("other_name").orocos_name
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
                deployment_task.should_receive(:remote_task_handles)
                               .and_return("mapped_task_name" => (remote_handles = Object.new))
                task.should_receive(:initialize_remote_handles).with(remote_handles).once
                deployment_task.should_receive(:ready?).and_return(true)
                deployment_task.task("mapped_task_name")
            end
            it "raises InternalError if the name provided as argument matches the model, but task_handles does not contain it" do
                deployment_task.should_receive(:remote_task_handles)
                               .and_return("invalid_name" => flexmock)
                deployment_task.should_receive(:ready?).and_return(true)
                assert_raises(InternalError) do
                    deployment_task.task("mapped_task_name")
                end
            end
            describe "slave tasks" do
                before do
                    @task_m = TaskContext.new_submodel do
                        event :ready
                    end

                    orogen_model = Orocos::Spec::Deployment.new(Orocos.default_loader, "deployment")
                    orogen_master = orogen_model.task "master", task_m.orogen_model
                    orogen_slave = orogen_model.task "slave", task_m.orogen_model
                    orogen_slave.slave_of(orogen_master)
                    @deployment_m = Deployment.new_submodel(orogen_model: orogen_model)
                end

                it "adds its master task as dependency" do
                    plan.add(deployment_task = @deployment_m.new)
                    task = deployment_task.task("slave")
                    assert_same deployment_task, task.execution_agent
                    scheduler_task = task.child_from_role("scheduler")
                    assert_equal "master", scheduler_task.orocos_name
                    assert_same deployment_task, scheduler_task.execution_agent
                end

                it "auto-selects the configuration of the master task" do
                    @task_m.configuration_manager.add "master", {}

                    plan.add(deployment_task = @deployment_m.new)
                    task = deployment_task.task("slave")
                    assert_equal %w[default master],
                                 task.child_from_role("scheduler").conf
                end

                it "constrains the configuration of the slave task" do
                    plan.add(deployment_task = @deployment_m.new)
                    scheduler_task = deployment_task.task("master")
                    scheduled_task = deployment_task.task("slave")
                    assert scheduler_task.start_event.child_object?(
                        scheduled_task.start_event,
                        Roby::EventStructure::SyskitConfigurationPrecedence
                    )
                end

                it "reuses an existing agent" do
                    plan.add(deployment_task = @deployment_m.new)
                    master = deployment_task.task("master")
                    slave = deployment_task.task("slave")
                    assert_same master, slave.child_from_role("scheduler")
                end
            end
        end

        describe "runtime behaviour" do
            describe "start_event" do
                it "raises if the process name is set to nil" do
                    plan.add(task = deployment_task.model.new(process_name: nil))
                    failure_reason = expect_execution { task.start! }.to do
                        fail_to_start task, reason: Roby::CommandFailed.match
                                                                       .with_original_exception(ArgumentError)
                    end
                    assert_equal "must set process_name", failure_reason.original_exceptions.first.message
                end
                it "finds the process server from Syskit.process_servers and its on: option" do
                    process_server.should_receive(:start).once
                                  .with("mapped_task_name", deployment_m.orogen_model, any, any)
                                  .and_return(process)
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to_run
                end
                it "passes the process server's log dir as working directory" do
                    process_server.should_receive(:start).once
                                  .with(any, any, any, hsh(working_directory: log_dir))
                                  .and_return(process)
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to_run
                end
                it "passes the model-level run command line options to the process server start command" do
                    cmdline_options = { valgrind: true }
                    deployment_m.default_run_options.merge!(cmdline_options)
                    process_server.should_receive(:start)
                                  .with(any, any, any, hsh(cmdline_args: cmdline_options))
                                  .and_return(process)
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to_run
                end
                it "raises if the on option refers to a non-existing process server" do
                    plan.add(task = deployment_m.new(on: "does_not_exist"))
                    exception = expect_execution { task.start! }.to do
                        fail_to_start(
                            task, reason: Roby::CommandFailed
                                          .match
                                          .with_original_exception(ArgumentError)
                        )
                    end
                    assert_equal \
                        "there is no registered process server called does_not_exist, "\
                        "existing servers are: fixture, localhost, stubs",
                        exception.error.message
                end
                it "does not emit ready" do
                    process_server.should_receive(:start).and_return(process)
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false)
                        .to { not_emit deployment_task.ready_event }
                end
            end

            describe "monitoring for ready" do
                attr_reader :orocos_task
                before do
                    process_server.should_receive(:start).and_return(process)
                    @orocos_task = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new "test"
                    end
                end
                after do
                    orocos_task.dispose
                end

                it "does not emit ready if the process is not ready yet" do
                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false).to_run
                    sync = Concurrent::Event.new
                    process.should_receive(:resolve_all_tasks)
                           .and_return do
                               sync.set
                               nil
                           end
                    sync.wait
                    expect_execution { sync.wait }
                        .join_all_waiting_work(false)
                        .to { not_emit deployment_task.ready_event }
                end

                it "is interrupted by the stop command" do
                    expect_execution do
                        deployment_task.start!
                        deployment_task.stop!
                    end.to do
                        not_emit deployment_task.ready_event
                        emit deployment_task.stop_event
                    end
                end

                def make_deployment_ready
                    unless execution_engine.in_propagation_context?
                        return expect_execution { make_deployment_ready }
                               .to { emit deployment_task.ready_event }
                    end

                    process.should_receive(:resolve_all_tasks)
                           .and_return("mapped_task_name" => orocos_task)
                    deployment_task.start!
                end

                def add_deployed_task(name: "mapped_task_name")
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

                it "polls for process readiness" do
                    sync = Concurrent::Event.new
                    process.should_receive(:resolve_all_tasks)
                           .and_return do
                        if !sync.set?
                            sync.set
                            nil
                        else Hash["mapped_task_name" => orocos_task]
                        end
                    end

                    expect_execution { deployment_task.start! }
                        .join_all_waiting_work(false).to_run
                    sync.wait
                    expect_execution { sync.wait }
                        .to { emit deployment_task.ready_event }
                end
                it "fails the ready event if the ready event monitor raises" do
                    expect_execution do
                        process.should_receive(:resolve_all_tasks)
                               .and_raise(RuntimeError.new("some message"))
                        deployment_task.start!
                    end.to do
                        have_error_matching(
                            Roby::EmissionFailed
                            .match.with_origin(deployment_task.ready_event)
                        )
                    end
                end
                it "emits ready when the process is ready" do
                    make_deployment_ready
                    assert deployment_task.ready?
                end
                it "resolves all deployment tasks into task_handles using mapped names" do
                    make_deployment_ready
                    assert_equal orocos_task, deployment_task.remote_task_handles["mapped_task_name"].handle
                end
                it "creates state readers for each supported tasks" do
                    deployment_task.should_receive(:create_state_access).once
                                   .with(orocos_task, Hash)
                                   .and_return([state_reader = flexmock, state_getter = flexmock])
                    make_deployment_ready
                    assert_equal(state_reader,
                                 deployment_task.remote_task_handles["mapped_task_name"]
                                                .state_reader)
                    assert_equal(state_getter,
                                 deployment_task.remote_task_handles["mapped_task_name"]
                                                .state_getter)
                end
                it "passes the distance-to-syskit at state reader creation" do
                    deployment_task
                        .should_receive(:create_state_access).once
                        .with(orocos_task, distance: TaskContext::D_DIFFERENT_HOSTS)
                        .pass_thru
                    mock_raw_port(flexmock(orocos_task), "state")
                        .should_receive(:reader).once
                        .with(hsh(distance: TaskContext::D_DIFFERENT_HOSTS))
                        .pass_thru
                    make_deployment_ready
                end
                it "initializes supported task contexts" do
                    task = add_deployed_task
                    task.should_receive(:initialize_remote_handles).once
                        .with(->(remote) { remote.handle == orocos_task })
                    make_deployment_ready
                end
                it "passes handles already assigned to existing TaskContext to resolve_all_tasks" do
                    task = add_deployed_task
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once
                           .with("mapped_task_name" => orocos_task)
                           .and_return("mapped_task_name" => orocos_task)

                    make_deployment_ready
                end
                it "fails if the returned task handle does not match the expectation" do
                    task = add_deployed_task
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once
                           .and_return("invalid_name" => orocos_task)

                    exception = expect_execution { make_deployment_ready }
                                .to do
                        have_handled_error_matching Roby::EventHandlerError.match
                                                                           .with_origin(deployment_task.ready_event)
                                                                           .with_original_exception(InternalError)
                    end
                                .exception

                    assert_equal "expected #{process}'s reported tasks to include "\
                                 "'mapped_task_name' (mapped from 'task'), but got "\
                                 "handles only for invalid_name",
                                 exception.original_exceptions.first.message
                end
                it "fails an attached TaskContext if its orocos_name does not match the deployment's" do
                    task = add_deployed_task(name: "invalid_task_name")
                    task.orocos_task = orocos_task
                    process.should_receive(:resolve_all_tasks).once
                           .and_return("mapped_task_name" => orocos_task)

                    plan.unmark_permanent_task(task)
                    plan.unmark_permanent_task(task.execution_agent)
                    exception = expect_execution { make_deployment_ready }.to do
                        fail_to_start task, reason: Roby::CommandFailed.match
                                                                       .with_original_exception(InternalError)
                    end

                    assert_equal "#{task} is supported by #{deployment_task} but there does not seem to be any task called invalid_task_name on this deployment",
                                 exception.error.message
                end
            end

            describe "stop event" do
                attr_reader :orocos_task
                before do
                    process_server.should_receive(:start).and_return(process)
                    @orocos_task = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new "test"
                    end
                    flexmock(@orocos_task)
                    process.should_receive(:resolve_all_tasks)
                           .and_return("mapped_task_name" => orocos_task)
                    expect_execution { deployment_task.start! }
                        .to { emit deployment_task.ready_event }
                    plan.unmark_permanent_task(deployment_task)
                end
                after do
                    @orocos_task.dispose
                end
                it "cleans up all stopped tasks" do
                    orocos_task.should_receive(:rtt_state).and_return(:STOPPED)
                    orocos_task.should_receive(:cleanup).once
                    execute { deployment_task.stop! }
                end
                it "marks the task as ready to die" do
                    execute { deployment_task.stop! }
                    assert deployment_task.ready_to_die?
                end
                it "kills the process gracefully, but does not ask "\
                   "the process server to clean it up" do
                    process.should_receive(:kill).once
                           .with(false, cleanup: false, hard: false).pass_thru
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.stop_event }
                end
                it "does not attempt to cleanup if some tasks have a representation in "\
                   "the plan" do
                    deployment_task.task("mapped_task_name")
                    orocos_task.should_receive(:rtt_state).never
                    orocos_task.should_receive(:cleanup).never
                    process.should_receive(:kill).once
                           .with(false, cleanup: false, hard: true).pass_thru
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.stop_event }
                end
                it "does not cleanup and hard-kills the process if "\
                   "the kill event is called" do
                    orocos_task.should_receive(:rtt_state).never
                    orocos_task.should_receive(:cleanup).never
                    process.should_receive(:kill).once
                           .with(false, cleanup: false, hard: true).pass_thru
                    expect_execution { deployment_task.kill! }
                        .to { emit deployment_task.stop_event }
                end
                it "ignores com errors with the tasks" do
                    orocos_task.should_receive(:cleanup).and_raise(Orocos::ComError)
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.stop_event }
                end
                it "emits stop if kill fails with a communication error" do
                    process.should_receive(:kill).and_raise(Orocos::ComError)
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.failed_event }
                end
            end
        end

        describe "#dead!" do
            attr_reader :process
            describe "emitted terminal events" do
                attr_reader :orocos_task
                before do
                    deployment_m.event :terminal_e, terminal: true
                    execute { plan.clear }
                    process_server.should_receive(:start).and_return(process)
                    @orocos_task = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new "test"
                    end
                    process.should_receive(:resolve_all_tasks)
                           .and_return("mapped_task_name" => orocos_task)
                    plan.add_permanent_task(
                        @deployment_task = deployment_m
                        .new(process_name: "mapped_task_name", on: "fixture", name_mappings: Hash["task" => "mapped_task_name"])
                    )
                    expect_execution { deployment_task.start! }
                        .to { emit deployment_task.start_event }
                    plan.unmark_permanent_task(deployment_task)
                end
                after do
                    orocos_task.dispose
                end

                it "only emits stop if another terminal event was already emitted" do
                    execute { deployment_task.terminal_e_event.emit }
                    expect_execution { deployment_task.dead!(nil) }.to do
                        emit deployment_task.stop_event
                        not_emit deployment_task.success_event, deployment_task.failed_event
                    end
                end
                it "emits the failed event if no result was given" do
                    expect_execution { deployment_task.dead!(nil) }.to do
                        emit deployment_task.failed_event
                        not_emit deployment_task.signaled_event
                    end
                end
                it "emits the signaled event if the deployment was signaled" do
                    expect_execution { deployment_task.dead!(flexmock(success?: false, signaled?: true)) }.to do
                        emit deployment_task.signaled_event
                    end
                end
                it "emits the failed event if the deployment was both not succesful and not signaled" do
                    expect_execution { deployment_task.dead!(flexmock(success?: false, signaled?: false)) }.to do
                        emit deployment_task.failed_event
                        not_emit deployment_task.signaled_event
                    end
                end
                it "emits the success event if the deployment finished normally" do
                    expect_execution { deployment_task.dead!(flexmock(success?: true, signaled?: false)) }.to do
                        emit deployment_task.success_event
                    end
                end
            end
        end

        describe "#instanciate_all_tasks" do
            it "creates a task for each supported task context" do
                deployment_task.name_mappings["task"] = "mapped_task_name"
                deployment_task.should_receive(:task).with("mapped_task_name").once
                deployment_task.instanciate_all_tasks
            end
        end

        describe "using the ruby process server" do
            attr_reader :task_m, :deployment_m, :deployment
            before do
                Syskit.conf.register_process_server("test", Orocos::RubyTasks::ProcessManager.new, "")
                task_m = @task_m = TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
                end
                @deployment_m = Deployment.new_submodel(name: "deployment") do
                    task "task", task_m.orogen_model
                end
                Syskit.conf.process_server_for("test")
                      .register_deployment_model(deployment_m.orogen_model)
                plan.add(@deployment = deployment_m.new(on: "test"))
                expect_execution { deployment.start! }
                    .to { emit deployment.ready_event }
            end
            it "can start tasks defined on a ruby process server" do
                task = deployment.task("task")
                assert task.orocos_task
                assert "task", task.orocos_task.name
            end
            it "sets the orocos_task attribute to a RubyTaskContext" do
                assert_kind_of Orocos::RubyTasks::TaskContext, deployment.task("task").orocos_task
            end
            it "makes sure that the Ruby tasks are disposed when the deployment is stopped" do
                flexmock(deployment.task("task").orocos_task).should_receive(:dispose).once.pass_thru
                expect_execution { deployment.stop! }
                    .to { emit deployment.stop_event }
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

            def create_deployment(host_id, name: flexmock)
                process_server = ProcessServerFixture.new
                process = ProcessFixture.new(process_server)
                process_server.tasks["mapped_task_name"] = process
                log_dir = flexmock("log_dir")
                process_server_config =
                    Syskit.conf.register_process_server(name, process_server, log_dir, host_id: host_id)
                @stub_process_servers << process_server_config
                deployment_m.new(on: name)
            end
        end

        describe "#distance_to_syskit" do
            include stub_process_server_deployment_helpers

            it "returns D_SAME_PROCESS if called with a in-process process server" do
                d = create_deployment "syskit"
                assert_equal TaskContext::D_SAME_PROCESS, d.distance_to_syskit
            end
            it "returns D_SAME_HOST for process servers that run on localhost" do
                d = create_deployment "localhost"
                assert_equal TaskContext::D_SAME_HOST, d.distance_to_syskit
            end
            it "returns D_DIFFERENT_HOSTS for any other host_id" do
                d = create_deployment "something_else"
                assert_equal TaskContext::D_DIFFERENT_HOSTS, d.distance_to_syskit
            end
        end

        describe "#in_process?" do
            include stub_process_server_deployment_helpers

            it "returns true if called with a in-process process server" do
                assert create_deployment("syskit").in_process?
            end
            it "returns false for process servers that run on localhost" do
                refute create_deployment("localhost").in_process?
            end
            it "returns false for any other host_id" do
                refute create_deployment("host").in_process?
            end
        end

        describe "#on_localhost?" do
            include stub_process_server_deployment_helpers

            it "returns true if called with a in-process process server" do
                assert create_deployment("syskit").on_localhost?
            end
            it "returns true for process servers that run on localhost" do
                assert create_deployment("localhost").on_localhost?
            end
            it "returns false for any other host_id" do
                refute create_deployment("host").on_localhost?
            end
        end

        describe "#distance_to" do
            include stub_process_server_deployment_helpers

            it "returns D_SAME_PROCESS if called with self" do
                d0 = create_deployment "here"
                assert_equal TaskContext::D_SAME_PROCESS, d0.distance_to(d0)
            end
            it "returns D_SAME_PROCESS for process servers that run in-process" do
                d0 = create_deployment "syskit"
                d1 = create_deployment "syskit"
                assert_equal TaskContext::D_SAME_PROCESS, d0.distance_to(d1)
            end
            it "returns D_SAME_HOST if both tasks are executed from process servers on the same host" do
                d0 = create_deployment "test"
                d1 = create_deployment "test"
                assert_equal TaskContext::D_SAME_HOST, d0.distance_to(d1)
            end
            it "returns D_DIFFERENT_HOSTS if both tasks are from processes from different hosts" do
                d0 = create_deployment "here"
                d1 = create_deployment "there"
                assert_equal TaskContext::D_DIFFERENT_HOSTS, d0.distance_to(d1)
            end
        end

        describe "runtime state tracking" do
            attr_reader :orocos_task
            before do
                @orocos_task = Orocos.allow_blocking_calls do
                    Orocos::RubyTasks::TaskContext.new "#{Process.pid}-test"
                end
                process.should_receive(:resolve_all_tasks)
                       .and_return("mapped_task_name" => orocos_task)
                expect_execution { deployment_task.start! }
                    .to { emit deployment_task.ready_event }
            end
            after do
                orocos_task.dispose
            end

            describe "current configuration" do
                it "returns true if the configuration list differs" do
                    deployment_task.update_current_configuration("mapped_task_name", nil, ["test"], Set.new)
                    assert deployment_task.configuration_changed?("mapped_task_name", ["other"], Set.new)
                end
                it "returns true if the set of dynamic services differ" do
                    deployment_task.update_current_configuration("mapped_task_name", nil, ["test"], Set[1])
                    assert deployment_task.configuration_changed?("mapped_task_name", ["test"], Set[2])
                end
                it "returns false if both the configuration and the set of dynamic services are identical" do
                    deployment_task.update_current_configuration("mapped_task_name", nil, ["test"], Set[1])
                    refute deployment_task.configuration_changed?("mapped_task_name", ["test"], Set[1])
                end
            end
        end

        describe "#mark_changed_configuration_as_non_reusable" do
            before do
                @task_m = Syskit::TaskContext.new_submodel
                syskit_stub_conf @task_m, "test"
            end

            it "returns the orocos name of the deployed tasks that have a configuration section changed" do
                task = syskit_stub_deploy_configure_and_start(task_m.with_conf("test"))
                assert_equal Set[task.orocos_name], task.execution_agent
                                                        .mark_changed_configuration_as_not_reusable(task.model => ["test"])
            end
            it "does not return the orocos name of the deployed tasks that do not have any configuration section changed" do
                configured_deployment = syskit_stub_configured_deployment(task_m)
                plan.add(deployment_task = configured_deployment.new)
                expect_execution { deployment_task.start! }
                    .to { emit deployment_task.ready_event }
                assert_equal Set[], deployment_task
                    .mark_changed_configuration_as_not_reusable(task_m => ["test"])
            end
            it "ignores never-configured tasks" do
                task = syskit_stub_and_deploy(task_m.with_conf("test"))
                assert_equal Set[], task.execution_agent
                                        .mark_changed_configuration_as_not_reusable(task.model => ["test"])
            end
        end
    end
end
