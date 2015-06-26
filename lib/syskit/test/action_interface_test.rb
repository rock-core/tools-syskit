module Syskit
    module Test
        # Base class for testing action interfaces
        class ActionInterfaceTest < Spec
            include Syskit::Test
            include ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    return @subject_syskit_model
                elsif desc.kind_of?(Roby::Actions::Interface)
                    return desc
                else
                    super
                end
            end

            def self.method_missing(m, *args)
                if desc.find_action_by_name(m)
                    return desc.send(m, *args)
                else super
                end
            end
        end
    end
end

