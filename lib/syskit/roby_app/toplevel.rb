module Syskit
    module RobyApp
        # Extensions to the toplevel Roby object
        module Toplevel
            def orocos_engine
                Roby.app.orocos_engine
            end
        end
    end
end

