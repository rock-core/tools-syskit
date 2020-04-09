# frozen_string_literal: true

module Syskit
    module Actions
        # Action representation for syskit-specific objects
        class Action < Roby::Actions::Action
            # Return an InstanceRequirements that is equivalent to this action
            #
            # @return [InstanceRequirements]
            def to_instance_requirements
                model.to_instance_requirements(arguments)
            end

            # Create a new action with the same arguments but the requirements
            # rebound to a new profile
            #
            # @param [Profile] the profile onto which definitions should be
            #   rebound
            # @return [Action]
            def rebind_requirements(profile)
                model.rebind_requirements(profile).new(arguments)
            end

            def respond_to_missing?(m, include_private)
                model.requirements.respond_to?(m) || super
            end

            def method_missing(m, *args, &block)
                if model.requirements.respond_to?(m)
                    Action.new(model.public_send(m, *args, &block), arguments)
                else super
                end
            end
        end
    end
end
