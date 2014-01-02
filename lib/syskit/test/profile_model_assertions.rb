module Syskit
    module Test
        # Module that defines model-level assertions on profile definitions
        # and/or the actions created from these profile definitions
        #
        # @return [NetworkGeneration::Engine,Array<Component>] the engine used
        #   for generation and the toplevel tasks that are the
        #   result of the instanciation, in the same order than the actions that
        #   have been given
        module ProfileModelAssertions
            def try_instanciate(name, plan, actions, options = Hash.new)
                placeholder_tasks = actions.map do |act|
                    task =
                        if act.kind_of?(InstanceRequirements)
                            act.as_plan
                        else act.instanciate(plan)
                        end
                    if (planner = task.planning_task) && planner.respond_to?(:requirements)
                        plan.add_mission(task)
                        task
                    end
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                requirement_tasks = placeholder_tasks.map(&:planning_task)

                engine = Syskit::NetworkGeneration::Engine.new(plan)
                resolve_options = Hash[:requirement_tasks => requirement_tasks,
                                       :on_error => :commit].merge(options)
                engine.resolve(resolve_options)
                dataflow, hierarchy = name + "-dataflow.svg", name + "-hierarchy.svg"
                if Roby.app.public_logs?
                    Graphviz.new(plan).to_file('dataflow', 'svg', File.join(Roby.app.log_dir, dataflow))
                    Graphviz.new(plan).to_file('hierarchy', 'svg', File.join(Roby.app.log_dir, hierarchy))
                end
                placeholder_tasks.each do |task|
                    plan.remove_object(task)
                end
                return engine, root_tasks.map(&:task)
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def it_can_instanciate_together(*actions)
                it "can instanciate #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_instanciate_together(*actions)
                end
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {it_can_instanciate_together}
            def it_can_deploy_together(*actions)
                it "can deploy #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_deploy_together(*actions)
                end
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {it_can_configure_together}
            def it_can_configure_together(*actions)
                it "can configure #{actions.map(&:name).sort.join(", ")} together" do
                    assert_can_configure_together(*actions)
                end
            end

            # Verifis that a syskit-generated action can be instanciated
            #
            # Note that it passes even though it cannot be deployed (e.g. if some
            # components do not have a corresponding deployment)
            def it_can_instanciate(action)
                it "can instanciate #{action.name}" do
                    assert_can_instanciate_together(action)
                end
            end

            # Verifies that all syskit-generated actions of this interface can
            # be instanciated
            #
            # Note that it passes even though it cannot be deployed (e.g. if some
            # components do not have a corresponding deployment)
            def it_can_instanciate_all(options = Hash.new)
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
            def it_can_deploy(action)
                it "can deploy #{action.name}" do
                    assert_can_deploy_together(action)
                end
            end

            # Verifies that all syskit-generated actions from this interface can
            # be fully deployed
            #
            # It is stronger (and therefore includes)
            # {it_can_instanciate_all}
            def it_can_deploy_all(options = Hash.new)
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
            def it_can_configure(action)
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
            def it_can_configure_all(options = Hash.new)
                options = Kernel.validate_options options, :except => []
                exceptions = Array(options.delete(:except)).map(&:model)
                desc.each_action do |act|
                    if !exceptions.include?(act)
                        it_can_configure act
                    end
                end
            end
        end
    end
end

