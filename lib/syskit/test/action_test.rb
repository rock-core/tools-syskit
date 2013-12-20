module Syskit
    module Test
        # Base class for tests whose subject is an action
        class ActionTest < Spec
            include Syskit::Test
            include Syskit::Test::ProfileAssertions

            # Tests that the tested syskit-generated actions can be instanciated
            # together
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def self.it_can_be_instanciated
                assert_can_instanciate_together(desc)
            end

            # Tests that the given syskit-generated actions can be deployed
            #
            # It is stronger (and therefore includes)
            # {it_can_be_instanciated}
            def self.it_can_be_deployed
                assert_can_deploy_together(desc)
            end

            # Tests that the given syskit-generated actions can be deployed and that
            # the #configure method of the task contexts used in the generated
            # network can be called successfully
            #
            # It is stronger (and therefore includes)
            # {it_can_be_deployed}
            def self.it_can_be_configured
                assert_can_configure_together(desc)
            end
        end
    end
end

