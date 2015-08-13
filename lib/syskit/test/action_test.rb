module Syskit
    module Test
        # Base class for tests whose subject is an action
        class ActionTest < Spec
            include Syskit::Test
            include Syskit::Test::ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    return @subject_syskit_model
                elsif desc.kind_of?(Roby::Actions::Action)
                    return desc
                else
                    super
                end
            end
        end
    end
end

