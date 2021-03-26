# frozen_string_literal: true

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

            # Exceptions raised by failed assertions
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
                if arg.respond_to?(:each_action)
                    arg.each_action.map(&:to_action)
                elsif arg.respond_to?(:to_action)
                    [arg.to_action]
                elsif arg.respond_to?(:flat_map)
                    arg.flat_map { |a| Actions(a) }
                elsif arg.respond_to?(:to_instance_requirements)
                    Actions::Model::Action.new(arg)
                else
                    raise ArgumentError,
                          "expected an action or a collection of actions, but got "\
                          "#{arg} of class #{arg.class}"
                end
            end

            # Like #Actions, but expands coordination models into their
            # consistuent actions
            def AtomicActions(arg)
                Actions(arg).flat_map do |action|
                    expand_coordination_models(action)
                end
            end

            # Like {#AtomicActions} but filters out actions that cannot be
            # handled by the bulk assertions, and returns them
            #
            # @param [Array,Action] arg the action that is expanded
            # @param [Array<Roby::Actions::Action>] actions that
            #   should be ignored. Actions are compared on the basis of their
            #   model (arguments do not count)
            def BulkAssertAtomicActions(arg, exclude: [])
                exclude = Actions(exclude).map(&:model)
                skipped_actions = []
                actions = AtomicActions(arg).find_all do |action|
                    if exclude.include?(action.model)
                        false
                    elsif !action.kind_of?(Actions::Action) &&
                          action.has_missing_required_arg?
                        skipped_actions << action
                        false
                    else
                        true
                    end
                end
                skipped_actions.delete_if do |skipped_action|
                    actions.any? { |action| action.model == skipped_action.model }
                end
                [actions, skipped_actions]
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
            def assert_is_self_contained(
                action_or_profile = subject_syskit_model,
                message: "%s is not self contained", exclude: [], **instanciate_options
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: "\
                          "#{skip}, pass them to the 'exclude' argument to #{__method__}"
                end

                actions.each do |act|
                    syskit_assert_action_is_self_contained(
                        act, message: message, **instanciate_options
                    )
                end
            end

            def syskit_assert_action_is_self_contained(
                action, message: "%s is not self contained", **instanciate_options
            )
                self.assertions += 1
                syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                task = syskit_deploy(
                    action, syskit_engine: syskit_engine,
                            compute_policies: false, compute_deployments: false,
                            validate_generated_network: false, **instanciate_options
                )
                still_abstract = plan.find_local_tasks(Syskit::Component)
                                     .abstract.to_set
                still_abstract &= plan.compute_useful_tasks([task])
                tags, other = still_abstract.partition do |abstract_task|
                    abstract_task.class <= Actions::Profile::Tag
                end

                reference_profile = subject_syskit_model
                if reference_profile.respond_to?(:profile) # action interface
                    reference_profile = reference_profile.profile
                end

                tags_from_other = tags.find_all do |tag|
                    tag.class.profile != reference_profile
                end

                if !other.empty?
                    assertion_failure =
                        Roby::Test::Assertion.new(
                            TaskAllocationFailed.new(syskit_engine, other)
                        )

                    raise assertion_failure, format(message, action.to_s)

                elsif !tags_from_other.empty?
                    other_profiles =
                        tags_from_other.map { |t| t.class.profile }.uniq
                    assertion_failure =
                        Roby::Test::Assertion.new(
                            TaskAllocationFailed.new(syskit_engine, tags)
                        )

                    raise assertion_failure,
                          "#{action} contains tags from another profile (found "\
                          "#{other_profiles.map(&:name).sort.join(', ')}, "\
                          "expected #{reference_profile}"
                end

                plan.unmark_mission_task(task)
                expect_execution.garbage_collect(true).to_run
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(action, e), e.message, e.backtrace
            end

            # Spec-style call for {#assert_is_self_contained}
            #
            # @example verify that all definitions of a profile are self-contained
            #   describe MyBundle::Profiles::MyProfile do
            #     it { is_self_contained }
            #   end
            def is_self_contained(action_or_profile = subject_syskit_model, **options)
                assert_is_self_contained(action_or_profile, **options)
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
            def assert_can_instanciate(
                action_or_profile = subject_syskit_model,
                exclude: [], together_with: []
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: "\
                          "#{skip}, pass them to the 'exclude' argument to #{__method__}"
                end

                together_with = validate_actions(together_with) do |skip|
                    flunk "could not validate some non-Syskit actions given to "\
                          "`together_with`: #{skip}, pass them to the 'exclude' "\
                          "argument to #{__method__}"
                end

                actions.each do |action|
                    tasks = assert_can_instanciate_together(action, *together_with)
                    Array(tasks).each { |t| plan.unmark_mission_task(t) }
                    yield(action, tasks, together_with: together_with) if block_given?
                    expect_execution.garbage_collect(true).to_run
                end
            end

            # Spec-style call for {#assert_can_instanciate}
            #
            # @example verify that all definitions of a profile can be instanciated
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate }
            #   end
            def can_instanciate(
                action_or_profile = subject_syskit_model, together_with: []
            )
                assert_can_instanciate(action_or_profile, together_with: together_with)
            end

            # Tests that the given syskit-generated actions can be instanciated
            # together, i.e. that the resulting network is valid and
            # non-abstract (does not contain abstract tasks or data services)
            #
            # Note that it passes even though the resulting network cannot be
            # deployed (e.g. if some components do not have a corresponding
            # deployment)
            def assert_can_instanciate_together(*actions)
                actions = subject_syskit_model if actions.empty?
                self.assertions += 1
                syskit_deploy(AtomicActions(actions),
                              compute_policies: false,
                              compute_deployments: false)
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_instanciate_together}
            #
            # @example verify that all definitions of a profile can be instanciated
            #     all at the same time
            #
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_instanciate_together }
            #   end
            def can_instanciate_together(*actions)
                assert_can_instanciate_together(*actions)
            end

            # @api private
            #
            # Given an action, returns the list of atomic actions it refers to
            def expand_coordination_models(action)
                return [action] unless action.model.respond_to?(:coordination_model)

                action.model.coordination_model.each_task.flat_map do |coordination_task|
                    if coordination_task.respond_to?(:action)
                        expand_coordination_models(coordination_task.action)
                    end
                end.compact
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
            def assert_can_deploy(
                action_or_profile = subject_syskit_model,
                exclude: [], together_with: []
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: "\
                          "#{skip}, pass them to the 'exclude' argument to #{__method__}"
                end

                together_with = validate_actions(together_with) do |skip|
                    flunk "could not validate some non-Syskit actions given to "\
                          "`together_with` #{skip}, pass them to the 'exclude' "\
                          "argument to #{__method__}"
                end

                actions.each do |action|
                    task = assert_can_deploy_together(action, *together_with)
                    yield(action, tasks, together_with: together_with) if block_given?
                    Array(task).each { |t| plan.unmark_mission_task(t) }
                    expect_execution.garbage_collect(true).to_run
                end
            end

            # Spec-style call for {#assert_can_deploy}
            #
            # @example verify that each definition of a profile can be deployed
            #   describe MyBundle::Profiles::MyProfile do
            #     it { can_deploy }
            #   end
            def can_deploy(action_or_profile = subject_syskit_model, together_with: [])
                assert_can_deploy(action_or_profile, together_with: together_with)
            end

            # Tests that the given syskit-generated actions can be deployed together
            #
            # It is stronger (and therefore includes)
            # {assert_can_instanciate_together}
            def assert_can_deploy_together(*actions)
                actions = subject_syskit_model if actions.empty?
                self.assertions += 1
                syskit_deploy(AtomicActions(actions),
                              compute_policies: true,
                              compute_deployments: true)
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_deploy_together}
            #
            # @example
            #   # verify that all definitions of a profile can be deployed at
            #   # the same time
            #
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
                actions = subject_syskit_model if actions.empty?
                self.assertions += 1
                roots = assert_can_deploy_together(*AtomicActions(actions))
                # assert_can_deploy_together has one of its idiotic return
                # interface that returns either a single task if a single action
                # was given, or an array otherwise. I'd like to have someone
                # to talk me out of this kind of ideas.
                tasks = plan.compute_useful_tasks(Array(roots))
                task_contexts = tasks.find_all { |t| t.kind_of?(Syskit::TaskContext) }
                                     .each do |task_context|
                    unless task_context.plan
                        raise ProfileAssertionFailed.new(actions, nil),
                              "#{task_context} got garbage-collected before "\
                              "it got configured"
                    end
                end
                syskit_configure(task_contexts)
                roots
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(actions, e), e.message
            end

            # Spec-style call for {#assert_can_configure_together}
            def can_configure_together(*actions)
                assert_can_configure_together(*actions)
            end

            # @api private
            def validate_actions(action_or_profile, exclude: [])
                actions, skipped =
                    BulkAssertAtomicActions(action_or_profile, exclude: exclude)
                yield skipped.map(&:name).sort.join(", ") unless skipped.empty?

                actions
            end
        end
    end
end
