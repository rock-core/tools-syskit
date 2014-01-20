module Syskit
    module Test
        # Base class for testing action interfaces
        class ActionInterfaceTest < Spec
            include Syskit::Test
            include Syskit::Test::ActionAssertions

            def setup
                super
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def self.it_can_instanciate_together(*actions)
                it "can instanciate #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_instanciate_together(*actions)
                end
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {it_can_instanciate_together}
            def self.it_can_deploy_together(*actions)
                it "can deploy #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_deploy_together(*actions)
                end
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {it_can_configure_together}
            def self.it_can_configure_together(*actions)
                it "can configure #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_configure_together(*actions)
                end
            end

            # Verifis that a syskit-generated action can be instanciated
            #
            # Note that it passes even though it cannot be deployed (e.g. if some
            # components do not have a corresponding deployment)
            def self.it_can_instanciate(action)
                it "can instanciate #{action.name}" do
                    assert_can_instanciate_together(action)
                end
            end

            # Verifies that all syskit-generated actions of this interface can
            # be instanciated
            #
            # Note that it passes even though it cannot be deployed (e.g. if some
            # components do not have a corresponding deployment)
            def self.it_can_instanciate_all(options = Hash.new)
                options = Kernel.validate_options options, :except => []
                exceptions = Array(options.delete(:except)).map(&:model)
                desc.each_action do |act|
                    if !exceptions.include?(act)
                        it_can_instanciate act
                    end
                end
            end

            # Verifies that a syskit-generated action can be fully deployed
            #
            # It is stronger (and therefore includes)
            # {it_can_instanciate}
            def self.it_can_deploy(action)
                it "can deploy #{action.name}" do
                    assert_can_deploy_together(action)
                end
            end

            # Verifies that all syskit-generated actions from this interface can
            # be fully deployed
            #
            # It is stronger (and therefore includes)
            # {it_can_instanciate_all}
            def self.it_can_deploy_all(options = Hash.new)
                options = Kernel.validate_options options, :except => []
                exceptions = Array(options.delete(:except)).map(&:model)
                desc.each_action do |act|
                    if !exceptions.include?(act)
                        it_can_deploy act
                    end
                end
            end

            # Verifies that a syskit-generated action can be fully deployed and that
            # the used task contexts' #configure method can be successfully called
            #
            # It is stronger (and therefore includes)
            # {it_can_deploy}
            def self.it_can_configure(action)
                it "can configure #{action.name}" do
                    assert_can_configure_together(action)
                end
            end

            # Verifies that all syskit-generated actions of this interface can
            # be fully deployed and that the used task contexts' #configure
            # method can be successfully called
            #
            # It is stronger (and therefore includes)
            # {it_can_deploy}
            def self.it_can_configure_all(options = Hash.new)
                options = Kernel.validate_options options, :except => []
                exceptions = Array(options.delete(:except)).map(&:model)
                desc.each_action do |act|
                    if !exceptions.include?(act)
                        it_can_configure act
                    end
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

