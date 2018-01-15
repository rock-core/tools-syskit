require 'roby/cli/main'
require 'syskit/cli/gen_main'

module Syskit
    module CLI
        class Main < Roby::CLI::Main
            subcommand 'gen', GenMain
        end
    end
end