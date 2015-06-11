module Syskit
    module PlanExtension
        attr_accessor :syskit_engine
    end
    Roby::Plan.include PlanExtension
end


