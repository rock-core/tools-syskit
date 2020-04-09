# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test"

require "syskit/test/roby_app_helpers"

module Syskit
    module Test
        describe TaskContextTest do
            include Syskit::Test::RobyAppHelpers

            describe "abstract tasks" do
                it "auto-deploys an abstract task context when in abstract mode" do
                    out = capture_test_output do
                        dir = roby_app_setup_single_script
                        run_test dir, "abstract_simulation.rb"
                    end
                    assert_equal Set["TEST: CONFIGURE CALLED"], out
                end

                it "lets live tests run" do
                    out = capture_test_output do
                        dir = roby_app_setup_single_script
                        run_test dir, "abstract_live.rb", "--live"
                    end
                    assert_equal Set["TEST: CALLED"], out
                end
            end

            def run_test(dir, file, *args)
                full = File.join(__dir__, "fixtures", "task_context_test", file)
                assert roby_app_run("test", full, *args, chdir: dir).success?
            end

            def capture_test_output
                error = nil
                out, err = capture_subprocess_io do
                    begin
                        yield
                    rescue Minitest::Assertion, StandardError => e
                        error = e
                    end
                end

                if error
                    puts out
                    puts err
                    raise error
                end

                out.split("\n").map(&:chomp).grep(/^TEST: /).to_set
            end
        end
    end
end
