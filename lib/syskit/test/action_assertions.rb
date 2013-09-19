module Syskit
    module Test
        # Definition of the assertions common to all action-oriented tests
        module ActionAssertions
            def self.try_instanciate(plan, actions, options = Hash.new)
                requirement_tasks = actions.map do |act|
                    task = act.instanciate(plan)
                    if (planner = task.planning_task) && planner.respond_to?(:requirements)
                        plan.add_mission(task)
                        task
                    end
                end.compact
                requirement_tasks = requirement_tasks.map(&:planning_task)

                engine = Syskit::NetworkGeneration::Engine.new(plan)
                resolve_options = Hash[:requirement_tasks => requirement_tasks,
                                       :on_error => :discard].merge(options)
                engine.resolve(resolve_options)
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def assert_can_instanciate_together(*actions)
                ActionAssertions.try_instanciate(plan, actions,
                                 :compute_policies => false,
                                 :compute_deployments => false,
                                 :validate_network => false)
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {assert_can_instanciate_together}
            def assert_can_deploy_together(*actions)
                ActionAssertions.try_instanciate(plan, actions,
                                 :compute_policies => true,
                                 :compute_deployments => true,
                                 :validate_network => true)
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

                    task_context.configure
                end
            end
        end
    end
end

