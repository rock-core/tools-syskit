module Syskit
    module RobyApp
        # Extensions to the toplevel Roby object
        module Toplevel
            def syskit_engine
                Roby.app.plan.syskit_engine
            end
        end
    end
end

