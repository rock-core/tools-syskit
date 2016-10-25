module Syskit
    module Test
        # Defines assertions for definitions (Syskit::Actions::Profile) or
        # actions that are created from these definitions
        # (Roby::Actions::Interface)
        #
        # It assumes that the test class was extended using
        # {ProfileModelAssertions}
        module ProfileAssertions
            include NetworkManipulation

            class ProfileAssertionFailed < Roby::ExceptionBase
                attr_reader :actions

                def initialize(act, original_error)
                    @actions = Array(act)
                    super([original_error])
                end

                def pretty_print(pp)
                    pp.text "Failure while running an assertion on"
                    pp.nest(2) do
                        actions.each do |act|
                            pp.breakable
                            act.pretty_print(pp)
                        end
                    end
                end
            end

            # Validates an argument that can be an action, an action collection
            # (e.g. a profile) or an array of action, and normalizes it into an
            # array of actions
            #
            # @raise [ArgumentError] if the argument is invalid
            def Actions(arg)
                if arg.kind_of?(Syskit::Actions::Profile)
                    arg.each_action
                elsif arg.respond_to?(:to_action)
                    [arg]
                elsif arg.respond_to?(:flat_map)
                    arg.flat_map { |a| Actions(a) }
                else
                    raise ArgumentError, "expected an action or a collection of actions, but got #{arg}"
                end
            end

            # Tests that a definition or all definitions of a profile are
            # self-contained, that is that the only variation points in the
            # profile are profile tags.
            #
            # If given a profile as argument, or no profile at all, will test on
            # all definitions of resp. the given profile or the test's subject
            #
            # Note that it is a really good idea to maintain this property. No.
            # Seriously. Keep it in your tests.
            def assert_is_self_contained(action_or_profile = subject_syskit_model, message: "%s is not self contained", **instanciate_options)
                Actions(action_or_profile).each do |act|
                    begin
                        self.assertions += 1
                        syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                        task = syskit_deploy(act, syskit_engine: syskit_engine, compute_policies: false, compute_deployments: false, validate_generated_network: false, **instanciate_options)
                        still_abstract = plan.find_local_tasks(Syskit::Component).
                            abstract.to_a
                        tags, other = still_abstract.partition { |task| task.class <= Actions::Profile::Tag }
                        tags_from_other = tags.find_all { |task| task.class.profile != subject_syskit_model }
                        if !other.empty?
                            raise Roby::Test::Assertion.new(TaskAllocationFailed.new(syskit_engine, other)), message % [act.to_s]
                        elsif !tags_from_other.empty?
                            other_profiles = tags_from_other.map { |t| t.class.profile }.uniq
                            raise Roby::Test::Assertion.new(TaskAllocationFailed.new(syskit_engine, tags)), "#{act} contains tags from another profile (found #{other_profiles.map(&:name).sort.join(", ")}, expected #{subject_syskit_model}"
                        end
                        plan.unmark_mission_task(task)
                        plan.execution_engine.garbage_collect
                    rescue Exception => e
                        raise ProfileAssertionFailed.new(act, e), e.message
                    end
                end
            end

            # Spec-style call for {#assert_is_self_contained}
            #
            # @example verify that all definitions of a profile are self-contained
            #   describe MyBundle::Profiles::MyProfile do
            #     it { is_self_contained }
            #   end
            def is_self_contained(action_or_profile = subject_syskit_model, options = Hash.new)
                assert_is_self_contained(action_or_profile, options)
            end

            # Tests that the following definition can be successfully
            # instanciated in a valid, non-abstract network.
            # 
            # If given a profile, it will perform the test on each action of the
            # profile taken in isolation. If you want to test whether actions
            # can be instanciated at the same time, use
            # {#assert_can_instanciate_together}
            #
            # If called without argument, it tests the spec's context profile
            def assert_can_instanciate(action_or_profile = subject_syskit_model)
                Actions(action_or_profile).each do |act|
                    task = assert_can_instanciate_together(act)
                    plan.unmark_mission_task(task)
                    plan.execution_engine.garbage_collect
                end
            end

            # Spec-style call for {#assert_can_instanciate}
            #
            # @example verify that all definitions of a profile can be instanciated
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate }
            #   end
            def can_instanciate(action_or_profile = subject_syskit_model)
                assert_can_instanciate(action_or_profile)
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together, i.e. that the resulting network is valid and
            # non-abstract (does not contain abstract tasks or data services)
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def assert_can_instanciate_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                syskit_deploy(Actions(actions),
                                 compute_policies: false,
                                 compute_deployments: false)
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_instanciate_together}
            #
            # @example verify that all definitions of a profile can be instanciated all at the same time
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate_together }
            #   end
            def can_instanciate_together(*actions)
                assert_can_instanciate_together(*actions)
            end

            # Tests that the following syskit-generated actions can be deployed,
            # that is they result in a valid, non-abstract network whose all
            # components have a deployment
            #
            # If given a profile, it will perform the test on each action of the
            # profile taken in isolation. If you want to test whether actions
            # can be deployed at the same time, use
            # {#assert_can_deploy_together}
            #
            # If called without argument, it tests the spec's context profile
            def assert_can_deploy(action_or_profile = subject_syskit_model)
                Actions(action_or_profile).each do |act|
                    task = assert_can_deploy_together(act)
                    plan.unmark_mission_task(task)
                    plan.execution_engine.garbage_collect
                end
            end

            # Spec-style call for {#assert_can_deploy}
            #
            # @example verify that each definition of a profile can be deployed
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_deploy }
            #   end
            def can_deploy(action_or_profile = subject_syskit_model)
                assert_can_deploy(action_or_profile)
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {assert_can_instanciate_together}
            def assert_can_deploy_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                syskit_deploy(Actions(actions),
                                 compute_policies: true,
                                 compute_deployments: true)
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_deploy_together}
            #
            # @example verify that all definitions of a profile can be deployed at the same time
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_deploy_together }
            #   end
            def can_deploy_together(*actions)
                assert_can_deploy_together(*actions)
            end

            # Tests that the given syskit-generated actions can be deployed together
            # and that the task contexts #configure method can be called
            # successfully
            #
            # It requires running the actual deployments, even though the components
            # themselve never get started
            #
            # It is stronger (and therefore includes)
            # {assert_can_deploy_together}
            def assert_can_configure_together(*actions)
                if actions.empty?
                    actions = subject_syskit_model
                end
                self.assertions += 1
                roots = assert_can_deploy_together(*Actions(actions))
                # assert_can_deploy_together has one of its idiotic return
                # interface that returns either a single task if a single action
                # was given, or an array otherwise. I'd like to have someone
                # to talk me out of this kind of ideas.
                tasks = plan.compute_useful_tasks(Array(roots))
                tasks.find_all { |t| t.kind_of?(Syskit::TaskContext) }.
                    each do |task_context|
                        if !task_context.plan
                            raise ProfileAssertionFailed.new(actions, nil), "#{task_context} got garbage-collected before it got configured"
                        end
                        syskit_configure(task_context)
                    end
            rescue Exception => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_configure_together}
            def can_configure_together(*actions)
                assert_can_configure_together(*actions)
            end

        end
    end
end

