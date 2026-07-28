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

            describe "config" do
                before do
                    run_command_and_stop "roby gen app"
                    write_file "config/robots/gazebo.yml", <<~YAML
                        system_definitions:
                          sdf_model_parameters:
                            param1: value1
                            param2: value2
                            array_param: [1, 2]
                          enable_something: false
                          nil_param: null
                        other_config:
                          something: value3
                    YAML
                    write_file "config/robots/gazebo_test.yml", <<~YAML
                        system_definitions:
                          sdf_model_parameters:
                            param2: overriden_value2
                            array_param: [3]
                    YAML
                    # Declare the robot and alias in app.yml so Roby knows about it
                    write_file "config/app.yml", <<~YAML
                        robots:
                          aliases:
                            test_alias: gazebo_test
                          robots:
                            gazebo_test: gazebo
                    YAML
                end

                it "prints the full configuration of a given robot when no keys are specified" do
                    cmd = run_command_and_stop "syskit config gazebo_test"
                    expected = {
                        "system_definitions" => {
                            "sdf_model_parameters" => {
                                "param1" => "value1",
                                "param2" => "overriden_value2",
                                "array_param" => [1, 2, 3]
                            },
                            "enable_something" => false,
                            "nil_param" => nil
                        },
                        "other_config" => {
                            "something" => "value3"
                        }
                    }
                    assert_equal expected, YAML.safe_load(cmd.stdout)
                end

                it "prints the value of a single key when --key is specified" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key system_definitions.sdf_model_parameters.param1"
                    assert_equal "value1", YAML.safe_load(cmd.stdout)
                end

                it "properly preserves boolean false values when --key is specified" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key system_definitions.enable_something"
                    assert_equal false, YAML.safe_load(cmd.stdout)
                end

                it "properly preserves explicit nil values when --key is specified" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key system_definitions.nil_param"
                    assert_nil YAML.safe_load(cmd.stdout)
                end

                it "returns an error when querying a nested key inside a non-hash value" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key system_definitions.enable_something.nested", fail_on_error: false
                    assert_match /Key 'system_definitions.enable_something.nested' not found/, cmd.stderr
                    assert_equal 1, cmd.exit_status
                end

                it "returns an error for a non-existent key" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key non_existent", fail_on_error: false
                    assert_match /Key 'non_existent' not found/, cmd.stderr
                    assert_equal 1, cmd.exit_status
                end

                it "supports cumulative key filtering when multiple --key options are specified" do
                    cmd = run_command_and_stop "syskit config gazebo_test --key system_definitions.sdf_model_parameters.param1 --key other_config.something"
                    expected = {
                        "system_definitions" => {
                            "sdf_model_parameters" => {
                                "param1" => "value1"
                            }
                        },
                        "other_config" => {
                            "something" => "value3"
                        }
                    }
                    assert_equal expected, YAML.safe_load(cmd.stdout)
                end

                it "runs the command from a specific bundle when --from-bundle is specified" do
                    require "tmpdir"
                    Dir.mktmpdir do |dir|
                        bundle_dir = File.join(dir, "my_temp_bundle")
                        FileUtils.mkdir_p(File.join(bundle_dir, "config", "robots"))
                        FileUtils.touch(File.join(bundle_dir, "config", "bundle.yml"))
                        File.write(File.join(bundle_dir, "config", "robots", "gazebo.yml"), <<~YAML)
                            system_definitions:
                              enable_something: true
                        YAML
                        File.write(File.join(bundle_dir, "config", "app.yml"), <<~YAML)
                            robots:
                              robots:
                                gazebo: gazebo
                        YAML

                        set_environment_variable("ROCK_BUNDLE_PATH", dir)
                        cmd = run_command_and_stop "syskit config gazebo --from-bundle my_temp_bundle"
                        expected = {
                            "system_definitions" => {
                                "enable_something" => true
                            }
                        }
                        assert_equal expected, YAML.safe_load(cmd.stdout)
                        assert_equal 0, cmd.exit_status
                    end
                end

                it "returns an error for a non-existent bundle with --from-bundle" do
                    require "tmpdir"
                    Dir.mktmpdir do |dir|
                        set_environment_variable("ROCK_BUNDLE_PATH", dir)
                        cmd = run_command_and_stop "syskit config gazebo --from-bundle non_existent_bundle_test_cli", fail_on_error: false
                        assert_match /No bundle named 'non_existent_bundle_test_cli' found/, cmd.stderr
                        assert_equal 1, cmd.exit_status
                    end
                end
            end
        end
    end
end
