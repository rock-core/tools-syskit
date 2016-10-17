require 'roby/test/common'

require 'syskit'
require 'roby/schedulers/temporal'
require 'orocos/ruby_process_server'

module Syskit
    module Test
        extend Logger::Hierarchy
        extend Logger::Forward

    # Base functionality for all testing cases
    module Base
        def setup
            @task_stubs = Array.new
            @old_loglevel = Orocos.logger.level

            super
        end

        def teardown
            plug_connection_management
            begin
                super
            rescue ::Exception => e
                teardown_failure = e
            end

            @task_stubs.each do |t|
                t.dispose
            end

        ensure
            Orocos.logger.level = @old_loglevel if @old_loglevel
            if teardown_failure
                raise teardown_failure
            end
        end

        def plug_connection_management
            RobyApp::Plugin.plug_handler_in_roby(execution_engine, :connection_management)
        end
        def unplug_connection_management
            RobyApp::Plugin.unplug_handler_from_roby(execution_engine, :connection_management)
        end

        def assert_fails_to_start(task)
            yield
            assert task.failed_to_start?
        end

        def assert_event_emission_failed(expected_code_error = nil)
            e = assert_raises(Roby::EmissionFailed) do
                yield
            end
            if expected_code_error && !e.error.kind_of?(expected_code_error)
                flunk("expected a Roby::EmissionFailed wrapping #{expected_code_error}, but \"#{e.error}\" (#{e.error.class}) was raised")
            end
        end

        def assert_event_command_failed(expected_code_error = nil)
            e = assert_raises(Roby::CommandFailed) do
                yield
            end
            if expected_code_error && !e.error.kind_of?(expected_code_error)
                flunk("expected a Roby::CommandFailed wrapping #{expected_code_error}, but \"#{e.error}\" (#{e.error.class}) was raised")
            end
        end

        def run_engine(timeout, poll_period = 0.1)
            start_time = Time.now
            cycle_start = Time.now
            while Time.now < start_time + timeout
                process_events
                yield if block_given?

                sleep_time = Time.now - cycle_start - poll_period
                if sleep_time > 0
                    sleep(sleep_time)
                end
                cycle_start += poll_period
            end
        end
        
        # Verify that no sample arrives on +reader+ within +timeout+ seconds
        def assert_has_no_new_sample(reader, timeout = 0.2)
            run_engine(timeout) do
                if sample = reader.read_new
                    flunk("#{reader} has one new sample #{sample}, but none was expected")
                end
            end
            assert(true, "no sample got received by #{reader}")
        end

        # Verifies that +reader+ gets one sample within +timeout+ seconds
        def assert_has_one_new_sample(reader, timeout = 3)
            if reader.respond_to?(:to_orocos_port)
                reader = Orocos.allow_blocking_calls do
                    reader.to_orocos_port
                end
            end
            if !reader.respond_to?(:read_new)
                if reader.respond_to?(:reader)
                    reader = Orocos.allow_blocking_calls do
                        reader.reader
                    end
                end
            end
            run_engine(timeout) do
                if sample = reader.read_new
                    return sample
                end
            end
            flunk("expected to get one new sample out of #{reader}, but got none")
        end

        # Creates a new null type and returns it
        def stub_type(name)
            Roby.app.default_loader.
                resolve_type(name, define_dummy_type: true)
        end
    end
    end
end

