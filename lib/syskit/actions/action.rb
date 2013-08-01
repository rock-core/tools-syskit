module Syskit
    module Actions
        # Action representation for syskit-specific objects
        class Action < Roby::Actions::Action
            def to_instance_requirements
                req = model.requirements.dup
                req.with_arguments(arguments)
                req
            end

            def method_missing(m, *args, &block)
                if model.requirements.respond_to?(m)
                    Action.new(model.send(m, *args, &block), arguments)
                else super
                end
            end
        end
    end
end
