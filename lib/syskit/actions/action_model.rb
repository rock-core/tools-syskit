module Syskit
    module Actions
        module Models
        # Representation of the deployment of a syskit instance requirement on
        # the action interface
        class Action < Roby::Actions::Models::Action
            # The instance requirement object for this action
            #
            # It is the "pure" requirements, where the enclsoing DI context is
            # not yet injected
            #
            # @return [InstanceRequirements]
            attr_reader :requirements

            def initialize(requirements, doc = nil)
                super(doc)
                @requirements = requirements
                returns(requirements.proxy_task_model)
            end

            # Rebind this action to another action interface
            def rebind(action_interface_model)
                # NOTE: use_profile maps all definitions into the new profile.
                # NOTE: DI injection will happen at this point, and we just
                # NOTE: have to look for already-defined actions
                if overloaded = action_interface_model.actions[name]
                    overloaded
                else
                    dup
                end
            end

            def initialize_copy(old)
                super
                @requirements = old.requirements.dup
            end

            # @return [Action] an action instance based on this model
            def new(arguments = Hash.new)
                Actions::Action.new(self, arguments)
            end

            def plan_pattern(arguments = Hash.new)
                job_id, arguments = Kernel.filter_options arguments, :job_id

                req = to_instance_requirements(arguments)
                placeholder = req.as_plan(job_id)
                placeholder.planning_task.action_model = self
                placeholder.planning_task.action_arguments = arguments
                placeholder
            end

            def to_instance_requirements(arguments = Hash.new)
                if !requirements.has_template? && requirements.can_use_template?
                    requirements.compute_template
                end
                req = requirements.dup
                req.with_arguments(arguments)
                req
            end

            # Instanciate this action on the given plan
            def instanciate(plan, arguments = Hash.new)
                plan.add(task = plan_pattern(arguments))
                task
            end

            # Injects the tasks necessary to deploy #requirements on the plan
            # associated with the given action interface
            #
            # @param [ActionInterface] the action interface
            # @param [Hash] arguments the arguments (unused)
            # @return [Roby::Task] the action task
            def run(action_interface, arguments = Hash.new)
                instanciate(action_interface.plan, arguments)
            end

            # Called by Roby::Actions::Models::Action to modify self so that it is
            # droby-marshallable
            #
            # It only resets the requirements attribute, as InstanceRequirements
            # are not (yet) marshallable in droby
            def droby_dump!(dest)
                super
                @requirements = Syskit::InstanceRequirements.new
            end

            def method_missing(m, *args, &block)
                if requirements.respond_to?(m)
                    req = requirements.dup
                    req.send(m, *args, &block)
                    Actions::Models::Action.new(req, doc)
                else super
                end
            end
        end
        end
    end
end

