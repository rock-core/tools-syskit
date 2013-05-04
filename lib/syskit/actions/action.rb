module Syskit
    module Actions
        # Action representation for syskit-specific objects
        class Action < Roby::Actions::Action
            def use(*args)
                Action.new(model.use(*args), arguments)
            end

            def to_instance_requirements
                req = model.requirements.dup
                req.with_arguments(arguments)
                req
            end
        end
    end
end
