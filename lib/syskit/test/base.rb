# frozen_string_literal: true

require "roby/test/common"

require "syskit"
require "roby/schedulers/temporal"
require "orocos/ruby_process_server"

module Syskit
    module Test
        extend Logger::Hierarchy
        extend Logger::Forward

        # Base functionality for all testing cases
        module Base
            def setup
                @task_stubs = []
                @old_loglevel = Orocos.logger.level

                super
            end

            def teardown
                # Disable log output to avoid spurious "stopped / interrupting"
                registered_plans.each do |p|
                    if p.executable?
                        p.find_tasks(Syskit::TaskContext).each do |t|
                            flexmock(t).should_receive(:info)
                        end
                    end
                end

                plug_connection_management
                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                @task_stubs.each(&:dispose)
            ensure
                Orocos.logger.level = @old_loglevel if @old_loglevel
                if teardown_failure
                    raise teardown_failure
                end
            end

            def plug_requirement_modifications
                RobyApp::Plugin.plug_handler_in_roby(execution_engine, :apply_requirement_modifications)
            end

            def unplug_requirement_modifications
                RobyApp::Plugin.unplug_handler_from_roby(execution_engine, :apply_requirement_modifications)
            end

            def plug_connection_management
                RobyApp::Plugin.plug_handler_in_roby(execution_engine, :connection_management)
            end

            def unplug_connection_management
                RobyApp::Plugin.unplug_handler_from_roby(execution_engine, :connection_management)
            end

            # @deprecated use the expectations on {ExecutionExpectations} instead
            def assert_has_no_new_sample(reader, timeout = 0.2)
                Roby.warn_deprecated "#{__method__} is deprecated, use the have_no_new_sample expectation on expect_execution instead"
                expect_execution.to do
                    have_no_new_sample(reader, at_least_during: timeout)
                end
            end

            # @deprecated use the expectations on {ExecutionExpectations} instead
            def assert_has_one_new_sample(reader, timeout = 3)
                Roby.warn_deprecated "#{__method__} is deprecated, use the have_one_new_sample expectation on expect_execution instead"
                expect_execution.to do
                    have_one_new_sample(reader)
                end
            end

            # Creates a new null type and returns it
            def stub_type(name)
                Roby.app.default_loader
                    .resolve_type(name, define_dummy_type: true)
            end
        end
    end
end
