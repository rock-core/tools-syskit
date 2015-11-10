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

        def assert_event_command_failed(expected_code_error = nil)
            begin
                yield
                flunk("expected Roby::CommandFailed, but no exception was raised")
            rescue Roby::CommandFailed => e
                if !e.error.kind_of?(expected_code_error)
                    flunk("expected a Roby::CommandFailed wrapping #{expected_code_error}, but \"#{e.error}\" (#{e.error.class}) was raised")
                end
            rescue Exception => e
                flunk("expected Roby::CommandFailed, but #{e} was raised")
            end
        end

        def assert_raises(exception, &block)
            super(exception) do
                begin
                    yield
                rescue Exception => e
                    PP.pp(e, "")
                    raise
                end
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
                reader = reader.to_orocos_port
            end
            if !reader.respond_to?(:read_new)
                if reader.respond_to?(:reader)
                    reader = reader.reader
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

