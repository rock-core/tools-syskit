module Syskit
    module Coordination
        module TaskScriptExtension
            def method_missing(m, *args, &block)
                if m.to_s =~ /_port$/
                    instance_for(model.root).send(m, *args, &block)
                else super
                end
            end
        end
    end
end
Roby::Coordination::TaskScript.include Syskit::Coordination::TaskScriptExtension
