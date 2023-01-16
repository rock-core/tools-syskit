# frozen_string_literal: true

require "syskit/test/self"
require "roby/test/aruba_minitest"

module Syskit
    module CLI
        describe "syskit gen" do
            include Roby::Test::ArubaMinitest

            before do
                run_command_and_stop "syskit gen app"

                @target_path = make_tmppath
            end

            it "fails if the config does not load" do
                robot_config requires: <<~RUBY
                    raise
                RUBY

                cmd = doc_gen fail_on_error: false
                refute_equal 0, cmd.exit_status
            end

            it "allows multiple --set arguments" do
                robot_config requires: <<~RUBY
                    raise if !Conf.set1? || !Conf.set2?
                RUBY

                doc_gen "--set", "set1=true", "--set", "set2=true"
            end

            def doc_gen(*args, fail_on_error: true)
                run_command_and_stop "syskit doc gen #{@target_path} #{args.join(' ')}",
                                     fail_on_error: fail_on_error
            end

            def robot_config(requires: "")
                contents = <<~RUBY
                    Robot.requires do
                        #{requires}
                    end
                RUBY
                write_file "config/robots/default.rb", contents
            end
        end
    end
end
