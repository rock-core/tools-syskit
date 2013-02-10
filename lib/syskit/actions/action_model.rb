module Syskit
    module Actions
        # Representation of the deployment of a syskit instance requirement on
        # the action interface
        class ActionModel < Roby::Actions::ActionModel
            # The instance requirement object for this action
            # @return [InstanceRequirements]
            attr_reader :requirements

            def initialize(action_interface_model, requirements, doc = nil)
                super(action_interface_model, doc)
                @requirements = requirements
                returns(requirements.proxy_task_model)
            end

            def plan_pattern(arguments = Hash.new)
                requirements.as_plan
            end

            # Injects the tasks necessary to deploy #requirements on the plan
            # associated with the given action interface
            #
            # @param [ActionInterface] the action interface
            # @param [Hash] arguments the arguments (unused)
            # @return [Roby::Task] the action task
            def run(action_interface, arguments = Hash.new)
                req = requirements.dup
                req.with_arguments(arguments)
                action_interface.plan.add(task = req.as_plan)
                task
            end

            # Called by Roby::Actions::ActionModel to modify self so that it is
            # droby-marshallable
            #
            # It only resets the requirements attribute, as InstanceRequirements
            # are not (yet) marshallable in droby
            def droby_dump!(dest)
                super
                @requirements = Syskit::InstanceRequirements.new
            end
        end
    end
end

