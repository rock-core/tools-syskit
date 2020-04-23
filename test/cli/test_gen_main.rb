# frozen_string_literal: true

require "syskit/test/self"
require "roby/test/aruba_minitest"

module Syskit
    module CLI
        describe "syskit gen" do
            include Roby::Test::ArubaMinitest

            def assert_app_valid(*args)
                syskit_run  = run_command ["syskit", "run", *args].join(" ")
                syskit_quit = run_command "syskit quit --retry"
                assert_command_stops syskit_run
                assert_command_stops syskit_quit

                # Disable Lint/UselessAssignment as we do assign "uselessly"
                # in tests to show how it is done
                #
                # Note that we expect the user to go through the test file
                # before he/she commits it ...
                rubocop = run_command "rubocop --except Lint/UselessAssignment"
                assert_command_stops rubocop
            end

            def run_syskit_test(*args)
                syskit_test = run_command ["syskit", "test", *args].join(" ")
                assert_command_stops syskit_test
            end

            describe "creation of a new app in the current directory" do
                it "generates a new valid app" do
                    run_command_and_stop "syskit gen app"
                    assert_app_valid
                end
                it "creates the config/orogen directory and adds a file to ensure it's saved in git" do
                    run_command_and_stop "syskit gen app"
                    assert exist?("config/orogen/.gitkeep")
                end
            end

            describe "within an existing app" do
                before do
                    run_command_and_stop "syskit gen app"
                end

                describe "gen bus" do
                    it "generates a new valid bus model configuration" do
                        run_command_and_stop "syskit gen bus bla"
                        assert_app_valid "models/devices/bla.rb"
                        run_syskit_test "test/devices/test_bla.rb"
                    end
                end

                describe "gen dev" do
                    it "generates a new valid device configuration" do
                        run_command_and_stop "syskit gen dev bla"
                        assert_app_valid "models/devices/bla.rb"
                        run_syskit_test "test/devices/test_bla.rb"
                    end
                end

                describe "gen cmp" do
                    it "generates a new valid composition configuration" do
                        run_command_and_stop "syskit gen cmp bla"
                        assert_app_valid "models/compositions/bla.rb"
                        run_syskit_test "test/compositions/test_bla.rb"
                    end
                end

                describe "gen ruby-task" do
                    it "generates a new valid ruby task model" do
                        run_command_and_stop "syskit gen ruby-task bla"
                        assert_app_valid "models/compositions/bla.rb"
                        run_syskit_test "test/compositions/test_bla.rb"
                    end
                end

                describe "gen srv" do
                    it "generates a new valid service configuration" do
                        run_command_and_stop "syskit gen srv bla"
                        assert_app_valid "models/services/bla.rb"
                    end
                end

                describe "gen profile" do
                    it "generates a new valid profile" do
                        run_command_and_stop "syskit gen profile bla"
                        assert_app_valid "models/profiles/bla.rb"
                        run_syskit_test "test/profiles/test_bla.rb"
                    end
                end

                describe "gen orogen" do
                    it "generates extension points for an orogen project" do
                        write_file "models/pack/orogen/bla.orogen", <<-OROGEN_FILE
                        name 'bla'
                        task_context 'Task' do
                        end
                        OROGEN_FILE
                        run_command_and_stop "syskit gen orogen bla"
                        run_syskit_test "test/orogen/test_bla.rb"
                    end
                end

                describe "gen orogenconf" do
                    it "gracefully fails to generate a configuration file for a component that has no deployment" do
                        cmd = run_command "syskit gen orogenconf logger::Logger"
                        cmd.stop
                        assert_equal 1, cmd.exit_status
                        assert_match /failed to start a component of model logger::Logger, cannot create a configuration file with default values/,
                                     cmd.stderr
                    end
                end
            end
        end
    end
end
