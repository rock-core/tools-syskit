module Syskit
    module Test
        class RubyTaskContextTest < TaskContextTest
            def deploy_subject_syskit_model
                use_ruby_tasks self.class.subject_syskit_model => 'task_under_test'
            end
            def self.ensure_can_deploy_subject_syskit_model(*)
                # We can always deploy ruby task contexts
            end
        end
    end
end


