require 'roby/test/roby_app_helpers'

module Syskit
    module Test
        # Helpers to test a full Roby app started as a subprocess
        module RobyAppHelpers
            include Roby::Test::RobyAppHelpers

            def gen_app
                require 'syskit/cli/gen_main'
                Dir.chdir(app_dir) { CLI::GenMain.start(['app', '--quiet']) }
            end
        end
    end
end
