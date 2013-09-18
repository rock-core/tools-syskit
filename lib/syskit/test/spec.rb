module Syskit
    module Test
        class Spec < Roby::Test::Spec
            include Test
            include Test::ActionAssertions
            include Test::NetworkManipulation

            def plan; Roby.plan end
        end
    end
end

