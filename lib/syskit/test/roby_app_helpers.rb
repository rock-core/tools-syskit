# frozen_string_literal: true

require "roby/test/roby_app_helpers"

module Syskit
    module Test
        # Helpers to test a full Roby app started as a subprocess
        module RobyAppHelpers
            include Roby::Test::RobyAppHelpers

            def gen_app
                require "syskit/cli/gen_main"
                Dir.chdir(app_dir) { CLI::GenMain.start(["app", "--quiet"]) }
            end

            def roby_app_setup_single_script(*scripts)
                dir = super

                FileUtils.cp File.join(__dir__, "..", "cli", "gen", "syskit_app",
                                       "config", "init.rb"),
                             File.join(dir, "config", "init.rb")
                dir
            end
        end
    end
end
