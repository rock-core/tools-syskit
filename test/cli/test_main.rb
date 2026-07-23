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
                    roby_allocate_interface_server
                    run_cmd = run_roby_run
                    run_roby_client_and_stop "wait"
                    run_roby_client_and_stop "quit"
                    assert_command_stops run_cmd
                end
            end

            describe "bundle_dir" do
                it "returns the absolute path of an existing bundle" do
                    require "tmpdir"
                    Dir.mktmpdir do |dir|
                        bundle_dir = File.join(dir, "my_temp_bundle")
                        FileUtils.mkdir_p(File.join(bundle_dir, "config"))
                        FileUtils.touch(File.join(bundle_dir, "config", "bundle.yml"))

                        set_environment_variable("ROCK_BUNDLE_PATH", dir)
                        cmd = run_command_and_stop "syskit bundle_dir my_temp_bundle"
                        assert_equal File.realdirpath(bundle_dir), File.realdirpath(cmd.stdout.strip)
                        assert_equal 0, cmd.exit_status
                    end
                end

                it "returns an error for a non-existent bundle" do
                    require "tmpdir"
                    Dir.mktmpdir do |dir|
                        set_environment_variable("ROCK_BUNDLE_PATH", dir)
                        cmd = run_command_and_stop "syskit bundle_dir non_existent_bundle_test_cli",
                                                   fail_on_error: false
                        assert_match /No bundle named 'non_existent_bundle_test_cli' found/, cmd.stderr
                        assert_equal 1, cmd.exit_status
                    end
                end
            end
        end
    end
end
