module Syskit
    module Actions
        # Representation of the deployment of a syskit instance requirement on
        # the action interface
        class ActionModel < Roby::Actions::ActionModel
            # The instance requirement object for this action
            # @return [InstanceRequirements]
            attr_reader :requirements

            def initialize(action_interface_model, requirements)
                super(action_interface_model)
                @requirements = requirements
            end

            # The type of the action task
            # Unlike with normal actions, this is directly derived from
            # #requirements
            def returned_type
                requirements.proxy_task_model
            end

            def plan_pattern
                requirements.as_plan
            end

            # Injects the tasks necessary to deploy #requirements on the plan
            # associated with the given action interface
            #
            # @param [ActionInterface] the action interface
            # @param [Hash] arguments the arguments (unused)
            # @return [Roby::Task] the action task
            def run(action_interface, arguments = Hash.new)
                action_interface.plan.add(task = requirements.as_plan)
                task
            end
        end
    end
end

