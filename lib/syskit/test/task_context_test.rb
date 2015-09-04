module Syskit
    module Test
        # Base class for all spec contexts whose subject is a task context model
        class TaskContextTest < ComponentTest
            # Overloaded to automatically call {#deploy_subject_syskit_model}
            def setup
                super
                @deployed_subject_syskit_model = deploy_subject_syskit_model
            end

            # Define a deployment for the task model under test
            def deploy_subject_syskit_model
                task_context_m = self.class.subject_syskit_model.concrete_model
                if task_context_m.orogen_model.abstract?
                    # This task context is abstract, i.e. does not have a
                    # default deployment, and therefore cannot be deployed. Stub
                    # it if we are in stub mode, skip the test otherwise

                    if !app.simulation?
                        raise RuntimeError, "cannot deploy the abstract task context model #{task_context_m} in live mode"
                    end
                    task_context_m.abstract = false

                    process_name = OroGen::Spec::Project.default_deployment_name(task_context_m.orogen_model.name)
                    syskit_stub_deployment_model(nil, process_name) do
                        task process_name, task_context_m.orogen_model
                    end
                end

                use_deployment(task_context_m => 'task_under_test').first
            end

            # Returns the task model under test
            def subject_syskit_model
                model = self.class.subject_syskit_model
                model = syskit_stub_required_devices(model)
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

            # Automatically skip tests for which the task model under test is
            # not available
            def self.ensure_can_deploy_subject_syskit_model(test, app)
                orogen_model = subject_syskit_model.orogen_model

                if app.simulation?
                    begin
                        ruby_task = Orocos::RubyTasks::TaskContext.new(
                            "spec#{object_id}", model: orogen_model)
                        ruby_task.dispose
                    rescue ::Exception => e
                        test.skip("#{test.__full_name__} cannot run: #{e.message}")
                    end
                elsif orogen_model.abstract?
                    test.skip("#{test.__full_name__} cannot run: #{orogen_model.name} is abstract and we're in live mode")
                else
                    project_name = orogen_model.project.name
                    if !Orocos.default_pkgconfig_loader.has_project?(project_name)
                        test.skip("#{test.__full_name__} cannot run: oroGen project #{project_name} is not available")
                    end
                end
            end

            # Overloaded from Roby to call {.ensure_can_deploy_subject_syskit_model}
            def self.roby_should_run(test, app)
                super
                ensure_can_deploy_subject_syskit_model(test, app)
            end
        end
    end
end

