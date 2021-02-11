# frozen_string_literal: true

require "roby/test/self"
require "roby/cli/main"
require "roby/interface/rest"
require "roby/test/aruba_minitest"

module Roby
    module CLI
        describe Main do
            include Roby::Test::ArubaMinitest

            describe "the help messages" do
                it "accepts syskit help CMD for a thor command" do
                    cmd = run_command_and_stop "syskit help quit"
                    assert_match /quits a running Roby application to be available/,
                                 cmd.stdout
                end
                it "accepts syskit CMD --help for a thor command" do
                    cmd = run_command_and_stop "syskit quit --help"
                    assert_match /quits a running Roby application to be available/,
                                 cmd.stdout
                end
                it "accepts syskit help CMD for a plain script command" do
                    cmd = run_command_and_stop "syskit help process_server"
                    assert_match /sets the host to connect to as hostname/,
                                 cmd.stdout
                end
                it "accepts syskit CMD --help for a plain script command" do
                    cmd = run_command_and_stop "syskit process_server --help"
                    assert_match /sets the host to connect to as hostname/,
                                 cmd.stdout
                end
                it "provides a simple help message with 'syskit'" do
                    cmd = run_command_and_stop "syskit"
                    assert_match /Run 'syskit help <mode>' for more information/,
                                 cmd.stdout
                end
                it "provides a simple help message with 'syskit --help'" do
                    cmd = run_command_and_stop "syskit --help"
                    assert_match /Run 'syskit help <mode>' for more information/,
                                 cmd.stdout
                end
                it "provides a simple help message with 'syskit help'" do
                    cmd = run_command_and_stop "syskit help"
                    assert_match /Run 'syskit help <mode>' for more information/,
                                 cmd.stdout
                end
            end

            describe "running Roby CLI commands" do
                before do
                    run_command_and_stop "roby gen app"
                end

                it "forwards a Roby CLI command defined through Thor" do
                    run_cmd = run_command "roby run"
                    run_command_and_stop "roby wait"
                    run_command_and_stop "roby quit"
                    assert_command_stops run_cmd
                end
            end
        end
    end
end
