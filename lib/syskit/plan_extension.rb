module Syskit
    module ExecutablePlanExtension
        attr_accessor :syskit_engine
    end
    Roby::ExecutablePlan.include ExecutablePlanExtension
end


