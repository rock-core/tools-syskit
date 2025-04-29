# frozen_string_literal: true

$stdout.sync = true
require "roby/schedulers/temporal"
Roby.scheduler = Roby::Schedulers::Temporal.new

TOKEN = ENV.fetch("SYSKIT_TEST_MISSING_PROCESS_SERVER_TOKEN", nil)
PROCESS_SERVER_PORT = Integer(ENV.fetch("SYSKIT_TEST_MISSING_PROCESS_SERVER_PORT", nil))

Syskit.conf.remote_process_managers_initial_connection_timeout = 1
Syskit.conf.remote_process_managers_connection_timeout = 1
Syskit.conf.remote_process_managers_response_timeout = 1
Syskit.conf.remote_process_managers_accept_failed_connections = true
Syskit.conf.register_remote_manager(
    "test", "localhost", port: PROCESS_SERVER_PORT
)
test_remote_manager = Syskit.conf.process_server_config_for("test")
if test_remote_manager.available?
    puts "#{TOKEN} - failed - process manager available on start"
    Roby.app.quit
end

using_task_library "orogen_syskit_tests"

deadline = nil
spawned = false
Robot.controller do
    Roby.execution_engine.each_cycle do
        if test_remote_manager.available? && !spawned
            spawned = true
            task_m =
                OroGen.orogen_syskit_tests.Empty
                      .deployed_as("#{Process.pid}_missing_empty", on: "test")
            task = Roby.plan.add_mission_task(task_m)
            task.start_event.on do |_event|
                puts "#{TOKEN} - success"
                Roby.app.quit
            end
        end
    end

    deadline ||= Time.now + 10
    if Time.now > deadline
        puts "#{TOKEN} - failed"
        Roby.app.quit
    end
end
