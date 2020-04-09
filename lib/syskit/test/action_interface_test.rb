# frozen_string_literal: true

module Syskit
    module Test
        # Base class for testing action interfaces
        class ActionInterfaceTest < Spec
            include Syskit::Test
            include ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    @subject_syskit_model
                elsif desc.kind_of?(Class) && (desc <= Roby::Actions::Interface)
                    desc
                else
                    super
                end
            end

            def subject_syskit_model
                self.class.subject_syskit_model
            end

            def self.respond_to_missing?(m, include_private)
                !!subject_syskit_model.find_action_by_name(m) || super
            end

            def self.method_missing(m, *args, &block)
                if subject_syskit_model.find_action_by_name(m)
                    subject_syskit_model.public_send(m, *args, &block)
                else super
                end
            end

            def respond_to_missing?(m, include_private)
                !!subject_syskit_model.find_action_by_name(m) || super
            end

            def method_missing(m, *args, &block)
                if subject_syskit_model.find_action_by_name(m)
                    subject_syskit_model.public_send(m, *args, &block)
                else super
                end
            end
        end
    end
end
