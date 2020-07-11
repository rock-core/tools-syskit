# frozen_string_literal: true

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
                    returns(requirements.placeholder_model)
                end

                def to_s
                    name =
                        if (requirement_name = requirements.name)
                            "#{requirement_name}_def"
                        else
                            requirements.to_s
                        end

                    if requirements.respond_to?(:profile)
                        "#{name} of #{requirements.profile}"
                    else
                        name
                    end
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

                # Create a new action with the same arguments but the requirements
                # rebound to a new profile
                #
                # @param [Profile] the profile onto which definitions should be
                #   rebound
                # @return [Action]
                def rebind_requirements(profile)
                    requirements.rebind(profile).to_action_model
                end

                def initialize_copy(old)
                    super
                    @requirements = old.requirements.dup
                end

                # @return [Action] an action instance based on this model
                def new(**arguments)
                    Actions::Action.new(self, **arguments)
                end

                def plan_pattern(**arguments)
                    job_id = {}
                    if arguments.key?(:job_id)
                        job_id[:job_id] = arguments.delete(:job_id)
                    end
                    req = to_instance_requirements(**arguments)
                    placeholder = req.as_plan(**job_id)
                    placeholder.planning_task.action_model = self
                    placeholder.planning_task.action_arguments = req.arguments
                    placeholder
                end

                def to_instance_requirements(**arguments)
                    if !requirements.has_template? && requirements.can_use_template?
                        requirements.compute_template
                    end
                    req = requirements.dup
                    req.with_arguments(**arguments)
                    req
                end

                # Instanciate this action on the given plan
                def instanciate(plan, **arguments)
                    plan.add(task = plan_pattern(**arguments))
                    task
                end

                # Injects the tasks necessary to deploy #requirements on the plan
                # associated with the given action interface
                #
                # @param [ActionInterface] the action interface
                # @param [Hash] arguments the arguments (unused)
                # @return [Roby::Task] the action task
                def run(action_interface, **arguments)
                    instanciate(action_interface.plan, **arguments)
                end

                # Called by Roby::Actions::Models::Action to modify self so that it is
                # droby-marshallable
                #
                # It only resets the requirements attribute, as InstanceRequirements
                # are not (yet) marshallable in droby
                def droby_dump!(peer)
                    super
                    @requirements = peer.dump(requirements)
                end

                def proxy!(peer)
                    super
                    if @requirements_model # Backward compatibility
                        @requirements.add_models([peer.local_object(@requirements_model)])
                        @requirements.name = @requirements_name
                        @requirements.with_arguments(peer.local_object(@requirements_arguments))
                        @requirements_model = @requirements_name = @requirements_arguments = nil
                    else
                        @requirements = peer.local_object(@requirements)
                    end
                end

                def respond_to_missing?(m, include_private)
                    requirements.respond_to?(m) || super
                end

                def method_missing(m, *args, **kw, &block)
                    if requirements.respond_to?(m)
                        req = requirements.dup
                        req.send(m, *args, **kw, &block)
                        Actions::Models::Action.new(req, doc)
                    else super
                    end
                end
            end
        end
    end
end
