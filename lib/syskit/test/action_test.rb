# frozen_string_literal: true

module Syskit
    module Test
        # Base class for tests whose subject is an action
        class ActionTest < Spec
            include Syskit::Test
            include Syskit::Test::ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    @subject_syskit_model
                elsif desc.kind_of?(Roby::Actions::Action)
                    desc
                else
                    super
                end
            end
        end
    end
end
