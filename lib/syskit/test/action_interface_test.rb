module Syskit
    module Test
        # Base class for testing action interfaces
        class ActionInterfaceTest < Spec
            include Syskit::Test
            include ProfileAssertions
            extend ProfileModelAssertions

            def self.method_missing(m, *args)
                if desc.find_action_by_name(m)
                    return desc.send(m, *args)
                else super
                end
            end
        end
    end
end

