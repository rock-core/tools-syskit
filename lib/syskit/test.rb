# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['SYSKIT_ENABLE_COVERAGE'] == '1' || ENV['SYSKIT_ENABLE_COVERAGE'] == '2'
    begin
        require 'simplecov'
        SimpleCov.start
        if ENV['SYSKIT_ENABLE_COVERAGE'] == '2'
            require 'syskit'
            Syskit.warn "coverage has been automatically enabled, which has a noticeable effect on runtime"
            Syskit.warn "Set SYSKIT_ENABLE_COVERAGE=0 in your shell to disable"
        end

    rescue LoadError
        require 'syskit'
        Syskit.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
    rescue Exception => e
        require 'syskit'
        Syskit.warn "coverage is disabled: #{e.message}"
    end
end

require 'syskit'
require 'roby'
require 'roby/test/common'
require 'roby/schedulers/temporal'
require 'orocos/ruby_process_server'

require 'test/unit/testcase'
require 'flexmock/test_unit'
require 'minitest/spec'

if ENV['SYSKIT_ENABLE_PRY'] != '0'
    begin
        require 'pry'
    rescue Exception
        Syskit.warn "debugging is disabled because the 'pry' gem cannot be loaded"
    end
end

require 'syskit/test/network_manipulation'

module Syskit
    module Test
        include FlexMock::ArgumentTypes
        include FlexMock::MockContainer

        def setup
            @task_stubs = Array.new
            @old_loglevel = Orocos.logger.level

            Roby.app.filter_backtraces = false
            Syskit.process_servers['stubs'] = [Orocos::RubyProcessServer.new, ""]

            super
        end

        def teardown
            super

            @task_stubs.each do |t|
                t.dispose
            end

        ensure
            Orocos.logger.level = @old_loglevel if @old_loglevel
        end

        def deploy(*args, &block)
            syskit_run_deployer(*args, &block)
        end

        # Run Syskit's deployer (i.e. engine) on the current plan
        def syskit_run_deployer(base_task = nil, resolve_options = Hash.new, &block)
            if engine.running?
                execute do
                    syskit_engine.redeploy
                end
                engine.wait_one_cycle
            else
                syskit_engine.disable_updates
                if base_task
                    base_task = base_task.as_plan
                    plan.add_mission(base_task)

                    planning_task = base_task.planning_task
                    if !planning_task.running?
                        planning_task.start!
                    end
                    base_task = base_task.as_service
                end
                syskit_engine.enable_updates
                syskit_engine.resolve(resolve_options)
                if planning_task
                    planning_task.emit :success
                end
            end
            if block_given?
                execute(&block)
            end
            if base_task
                base_task.task
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
    end


    require 'syskit/self_test'

    require 'roby/test/spec'
    require 'syskit/test/action_assertions'
    require 'syskit/test/spec'
    require 'syskit/test/action_interface_test'
    require 'syskit/test/action_test'
    require 'syskit/test/component_test'
    MiniTest::Spec.register_spec_type Syskit::Test::ActionTest do |desc|
        desc.kind_of?(Roby::Actions::Models::Action) || desc.kind_of?(Roby::Actions::Action)
    end
    MiniTest::Spec.register_spec_type Syskit::Test::ComponentTest do |desc|
        (desc.kind_of?(Class) && desc <= Syskit::Component)
    end
    MiniTest::Spec.register_spec_type Syskit::Test::ActionInterfaceTest do |desc|
        (desc.kind_of?(Class) && desc <= Roby::Actions::Interface)
    end
end


