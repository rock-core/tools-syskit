module Syskit
    module Test
        # Defines assertions for definitions (Syskit::Actions::Profile) or
        # actions that are created from these definitions
        # (Roby::Actions::Interface)
        #
        # It assumes that the test class was extended using
        # {ProfileModelAssertions}
        module ProfileAssertions
            # Tests that the given syskit-generated actions can be instanciated
            # together
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def assert_can_instanciate_together(*actions)
                self.class.try_instanciate(__full_name__, plan, actions,
                                 :compute_policies => false,
                                 :compute_deployments => false)
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {assert_can_instanciate_together}
            def assert_can_deploy_together(*actions)
                self.class.try_instanciate(__full_name__, plan, actions,
                                 :compute_policies => true,
                                 :compute_deployments => true)
            end

            # Tests that the given syskit-generated actions can be deployed together
            # and that the task contexts #configure method can be called
            # successfully
            #
            # It requires running the actual deployments, even though the components
            # themselve never get started
            #
            # It is stronger (and therefore includes)
            # {assert_can_deploy_together}
            def assert_can_configure_together(*actions)
                assert_can_deploy_together(*actions)
                plan.find_tasks(Syskit::TaskContext).each do |task_context|
                    if task_context.kind_of?(Syskit::TaskContext) && (deployment = task_context.execution_agent)
                        if !deployment.running?
                            Syskit::RobyApp::Plugin.disable_engine_in_roby engine, :update_task_states do
                                deployment.start!
                            end
                        end

                        if !deployment.ready?
                            Syskit::RobyApp::Plugin.disable_engine_in_roby engine, :update_task_states do
                                assert_event_emission deployment.ready_event
                            end
                        end
                    end

                    # The task may have been garbage-collected while we were
                    # starting the deployment ... call #configure only if it is
                    # not the case
                    if task_context.plan
                        task_context.configure
                    end
                end
            end
        end
    end
end

