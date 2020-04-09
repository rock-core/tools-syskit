# frozen_string_literal: true

module Syskit
    module Test
        class ComponentTest < Spec
            include NetworkManipulation

            def self.subject_syskit_model
                if @subject_syskit_model
                    @subject_syskit_model
                elsif desc.respond_to?(:orogen_model)
                    desc
                else
                    super
                end
            end
        end
    end
end
