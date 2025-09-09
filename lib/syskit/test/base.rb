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
                @__syskit_test_updated_attrs = {}

                super
            end

            def teardown
                # Disable log output to avoid spurious "stopped / interrupting"
                __syskit_test_disable_taskcontext_info_messages

                plug_connection_management
                __syskit_test_restore_updated_attributes

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

            def __syskit_test_disable_taskcontext_info_messages
                registered_plans.each do |p|
                    next unless p.executable?

                    p.find_tasks(Syskit::TaskContext).each do |t|
                        flexmock(t).should_receive(:info)
                    end
                end
            end

            def __syskit_test_restore_updated_attributes
                @__syskit_test_updated_attrs.each do |(obj, setter), value|
                    obj.send(setter, value)
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

            # Update an object's attribute, restoring its original value on teardown
            #
            # @param [Object] object
            # @param [String,Symbol] name the attribute name. Predicate attributes are
            #   handled by removing the trailing question mark before adding the `=`
            # @param [Object] value the new value
            def update_and_restore_attr(object, name, value)
                name = name.to_s
                setter =
                    if name.end_with?("?")
                        "#{name[0..-2]}="
                    else
                        "#{name}="
                    end

                @__syskit_test_updated_attrs[[object, setter]] = object.send(name)
                object.send(setter, value)
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

            def assert_has_conf(task_model, section)
                assert task_model.configuration_manager.has_section?(section),
                       "#{section} configuration section is not defined for #{task_model}"
            end
        end
    end
end
