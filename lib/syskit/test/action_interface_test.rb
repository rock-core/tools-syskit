module Syskit
    module Test
        # Base class for testing action interfaces
        class ActionInterfaceTest < Spec
            include Syskit::Test
            include ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    return @subject_syskit_model
                elsif desc.kind_of?(Class) && (desc <= Roby::Actions::Interface)
                    return desc
                else
                    super
                end
            end

            def subject_syskit_model
                self.class.subject_syskit_model
            end

            def self.method_missing(m, *args)
                if subject_syskit_model.find_action_by_name(m)
                    return subject_syskit_model.send(m, *args)
                else super
                end
            end

            def method_missing(m, *args)
                if subject_syskit_model.find_action_by_name(m)
                    subject_syskit_model.send(m, *args)
                else super
                end
            end
        end
    end
end

