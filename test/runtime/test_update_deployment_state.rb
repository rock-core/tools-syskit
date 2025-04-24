# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test/roby_app_helpers"
require "syskit/process_managers/remote/server"

module Syskit
    module Runtime
        class ProcessServerFixture
            attr_reader :loader, :processes, :killed_processes

            def initialize
                @killed_processes = []
                @processes = {}
                @loader = FlexMock.undefined
            end

            def wait_termination
                dead_processes = @killed_processes
                @killed_processes = []
                dead_processes
            end

            def start(name, *)
                processes.fetch(name)
            end

            def wait_running(*process_names)
                resolved = {}
                process_names.each do |p_name|
                    resolved[p_name] = {}
                    @processes.each_value do |p|
                        resolved[p_name] = p.ior_mappings
                    end
                end
                resolved
            end

            def disconnect; end
        end

        describe ".update_deployment_states" do
            describe "system behaviour with remote manager availability" do
                include Syskit::Test::RobyAppHelpers

                after do
                    if @remote_process_server_pid
                        remote_process_server_quit(@remote_process_server_pid)
                    end
                end

                def roby_app_fixture_path
                    File.expand_path("fixtures", __dir__)
                end

                it "gracefully handles a process manager that appears after start" do
                    dir = roby_app_setup_single_script(
                        "missing_process_manager_on_start.rb"
                    )
                    port = roby_app_allocate_port
                    token = SecureRandom.hex(10)
                    env = {
                        "SYSKIT_TEST_MISSING_PROCESS_SERVER_PORT" => port.to_s,
                        "SYSKIT_TEST_MISSING_PROCESS_SERVER_TOKEN" => token
                    }

                    pid, = roby_app_start(
                        "run", "-c", "scripts/missing_process_manager_on_start.rb",
                        capture_output: true, chdir: dir, env: env
                    )
                    sleep 5

                    @remote_process_server_pid = remote_process_server_spawn(port)
                    assert_roby_app_exits(pid)
                    output = roby_app_captured_output(pid)
                    refute_match(/#{token} - failed/, output[:out])
                    assert_match(/#{token} - success/, output[:out])
                end
            end

            describe "#handle_dead_deployments" do
                it "calls #dead! on the dead deployments" do
                    client = flexmock
                    flexmock(Syskit.conf)
                        .should_receive(:each_process_server_config)
                        .and_return([flexmock(client: client, available?: true)])
                    client.should_receive(:wait_termination)
                          .and_return([[p = flexmock, s = flexmock]])
                    flexmock(Deployment).should_receive(:deployment_by_process).with(p)
                                        .and_return(d = flexmock(finishing?: true))
                    d.should_receive(:dead!).with(s).once
                    Runtime.update_deployment_states(plan)
                end
            end

            describe "#trigger_ready_deployments" do
                attr_reader :mocked_remote_tasks
                attr_reader :process_server_config

                before do
                    @mocked_remote_tasks = {
                        "first_process" => {
                            iors: {
                                "task_name" => "IOR",
                                "task2" => "IOR2"
                            }
                        },
                        "other_process" => {
                            iors: {
                                "third_task" => "IOR3",
                                "fourth_task" => "IOR4"
                            }
                        }
                    }
                    process_server = ProcessServerFixture.new
                    @process_server_config = Syskit.conf.register_process_server(
                        "fixture", process_server, flexmock("log_dir")
                    )
                end

                it "updates the deployments remote tasks when they are ready" do
                    client_mock = flexmock(process_server_config.client)
                    d1 = mocked_deployment(
                        "first_process", "fixture", mocked_remote_tasks["first_process"]
                    )
                    d2 = mocked_deployment(
                        "other_process", "fixture", mocked_remote_tasks["other_process"]
                    )

                    flexmock(Runtime)
                        .should_receive(:find_all_not_ready_deployments)
                        .and_return({ fixture: [d1, d2] })
                    flexmock(Syskit.conf)
                        .should_receive(:process_server_config_for)
                        .and_return(process_server_config)
                    client_mock.should_receive(:wait_running)
                               .and_return(mocked_remote_tasks)
                    Runtime.update_deployment_states(plan)
                end

                it "emits that the ready event failed and an error was received" do
                    mocked_remote_tasks["other_process"] = { error: "some error" }
                    client_mock = flexmock(process_server_config.client)
                    d1 = mocked_deployment(
                        "first_process", "fixture", mocked_remote_tasks["first_process"]
                    )
                    d2 = mocked_deployment(
                        "other_process", "fixture", mocked_remote_tasks["other_process"]
                    )

                    flexmock(Runtime)
                        .should_receive(:find_all_not_ready_deployments)
                        .and_return({ fixture: [d1, d2] })
                    flexmock(Syskit.conf)
                        .should_receive(:process_server_config_for)
                        .and_return(process_server_config)
                    client_mock.should_receive(:wait_running)
                               .and_return(mocked_remote_tasks)
                    Runtime.update_deployment_states(plan)
                end

                it "ignores the deployment when it hasnt received a result from " \
                   "wait running" do
                    client_mock = flexmock(process_server_config.client)
                    d1 = mocked_deployment(
                        "first_process", "fixture", mocked_remote_tasks["first_process"]
                    )

                    flexmock(Runtime)
                        .should_receive(:find_all_not_ready_deployments)
                        .and_return({ fixture: [d1] })
                    flexmock(Syskit.conf)
                        .should_receive(:process_server_config_for)
                        .and_return(process_server_config)
                    client_mock.should_receive(:wait_running)
                               .and_return({ first_process: nil })
                    flexmock(d1.ready_event).should_receive(:emit_failed).never
                    flexmock(d1).should_receive(:update_remote_tasks).never
                    Runtime.update_deployment_states(plan)
                end

                it "ignores the deployment when its ready event is pending" do
                    client_mock = flexmock(process_server_config.client)
                    d1 = mocked_deployment(
                        "first_process", "fixture", mocked_remote_tasks["first_process"],
                        pending: true
                    )

                    flexmock(Runtime)
                        .should_receive(:find_all_not_ready_deployments)
                        .and_return({ fixture: [d1] })
                    flexmock(Syskit.conf)
                        .should_receive(:process_server_config_for)
                        .and_return(process_server_config)
                    client_mock.should_receive(:wait_running)
                               .and_return({
                                               "first_process" => {
                                                   iors: {
                                                       "task_name" => "IOR",
                                                       "task2" => "IOR2"
                                                   }
                                               }
                                           })
                    flexmock(d1.ready_event).should_receive(:emit_failed).never
                    flexmock(d1).should_receive(:update_remote_tasks).never
                    Runtime.update_deployment_states(plan)
                end

                def mocked_deployment(
                    process_name, process_server_name, remote_tasks, pending: false
                )
                    ready_event = flexmock({ pending?: pending })
                    mock = flexmock({ process_name: process_name,
                                      arguments: { on: process_server_name },
                                      ready_event: ready_event })

                    error = remote_tasks[:error]
                    if error
                        mock.ready_event.should_receive(:emit_failed).with(error)
                        mock.should_receive(:update_remote_tasks).never
                    else
                        mock.should_receive(:ready_event).never
                        mock.should_receive(:update_remote_tasks)
                            .with(remote_tasks[:iors])
                    end
                    mock
                end
            end

            def remote_process_server_spawn(port)
                log_dir = make_tmpdir
                pid = spawn(
                    "syskit", "process_server",
                    "--log-dir=#{log_dir}", "--port=#{port}",
                    chdir: log_dir, out: "/dev/null", err: "/dev/null"
                )
                register_pid(pid)
                pid
            end

            def remote_process_server_quit(pid)
                Process.kill "INT", pid
                assert_process_exits(pid)
            end
        end
    end
end
