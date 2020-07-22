# frozen_string_literal: true

module Syskit
    module Test
        # Base class for all spec contexts whose subject is a task context model
        class TaskContextTest < ComponentTest
            # Overloaded to automatically call {#deploy_subject_syskit_model}
            def setup
                super

                task_context_m = self.class.subject_syskit_model.concrete_model
                if app.simulation? || !task_context_m.orogen_model.abstract?
                    @deployed_subject_syskit_model = deploy_subject_syskit_model
                end
            end

            # Define a deployment for the task model under test
            def deploy_subject_syskit_model
                task_context_m = self.class.subject_syskit_model.concrete_model
                unless task_context_m.orogen_model.abstract?
                    return use_deployment(task_context_m => "task_under_test").first
                end

                # This task context is abstract, i.e. does not have a
                # default deployment, and therefore cannot be deployed. Stub
                # it if we are in stub mode, skip the test otherwise

                unless app.simulation?
                    raise "cannot deploy the abstract task context model "\
                          "#{task_context_m} in live mode"
                end

                task_context_m.abstract = false

                process_name = OroGen::Spec::Project
                               .default_deployment_name(task_context_m.orogen_model.name)
                syskit_stub_configured_deployment(nil, process_name) do
                    task process_name, task_context_m.orogen_model
                end
            end

            # Returns the task model under test
            def subject_syskit_model
                model = self.class.subject_syskit_model
                model = @__stubs.stub_required_devices(model)
                model.prefer_deployed_tasks(@deployed_subject_syskit_model)
                model
            end

            # @deprecated use instead
            #   it { is_configurable }
            def self.it_should_be_configurable
                Test.warn "it_should_be_configurable is deprecated, use"
                Test.warn "  it { is_configurable } instead"
                it { is_configurable }
            end

            # Tests that the task can be configured
            #
            # The argument can be any instance requirement, so that one can e.g. test
            # with particular arguments applied.
            #
            # @example test configuration with a particular argument set
            #   assert_is_configurable Task.with_argument(test: 10)
            #
            # @example test configuration with some dynamic services instanciated
            #   model = Task.specialize
            #   model.require_dynamic_service('srv')
            #   assert_is_configurable model
            #
            def assert_is_configurable(task_model = subject_syskit_model)
                syskit_deploy_and_configure(task_model)
            end

            # Spec-style variant to {#assert_is_configurable}
            #
            # @example test that {#configure} passes
            #   module OroGen::AuvControl
            #     describe Task do
            #       it { is_configurable }
            #     end
            #   end
            def is_configurable(task_model = subject_syskit_model)
                assert_is_configurable(task_model)
            end
        end
    end
end
