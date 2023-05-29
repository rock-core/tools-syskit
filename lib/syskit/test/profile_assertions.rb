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

            # @api private
            #
            # Find all planning tasks in a task hierarchy and return the resolved actions
            #
            # @param [Roby::Task] task the hierarchy's root task
            # @return [Array<Roby::Actions::Action>] the resolved actions. The method
            #   finds tasks with an action planner, syskit requirement tasks as well
            #   as expands state machines to find actions related to states.
            def resolve_actions_from_plan(task)
                actions = []
                queue = [task]
                until queue.empty?
                    t = queue.shift
                    queue.concat t.children
                    actions.concat expand_task_coordination_models(t)

                    next unless (planner = t.planning_task)

                    if planner.respond_to?(:requirements)
                        actions << planner.requirements.to_action
                    elsif planner.respond_to?(:action_model)
                        actions << planner.action_model.new(planner.action_arguments)
                    end
                end

                actions
            end

            # @api private
            #
            # Validates an argument that can be an action, an action collection
            # (e.g. a profile) or an array of action, and normalizes it into an
            # array of actions
            #
            # @raise [ArgumentError] if the argument is invalid
            def ActionModels(arg)
                if arg.respond_to?(:each_action)
                    ActionModels(arg.each_action)
                elsif arg.respond_to?(:to_action)
                    [arg.to_action.model]
                elsif arg.respond_to?(:flat_map)
                    arg.flat_map { |a| ActionModels(a) }
                elsif arg.respond_to?(:to_instance_requirements)
                    [Actions::Model::Action.new(arg)]
                else
                    raise ArgumentError,
                          "expected an action or a collection of actions, but got "\
                          "#{arg} of class #{arg.class}"
                end
            end

            # @api private
            #
            # Helper to {#Actions} to resolve a list of actions from a method action
            #
            # It returns either the actions that can be found from the instanciated
            # method action, or itself if it has missing required arguments
            #
            # @param [Roby::Actions::Action] arg the method action
            # @return [Array<#to_action>] the resolved actions
            def actions_from_method_action(arg)
                return [arg] if arg.has_missing_required_arg?

                plan = Roby::Plan.new
                task = arg.instanciate(plan)

                # Now find the new actions
                resolve_actions_from_plan(task).flat_map { |a| Actions(a) }
            end

            # @api private
            #
            # Resolves all reachable syskit actions from an argument that can be
            # an action, an action collection (e.g. a profile or action interface),
            # or an array of actions
            #
            # The method returns as-is method actions that cannot be instanciated
            # because of missing required arguments. Use {#BulkAssertAtomicActions} to
            # filter these out automatically
            #
            # @raise [ArgumentError] if the argument is invalid
            def Actions(arg)
                if arg.respond_to?(:each_action)
                    arg.each_action.flat_map do |a|
                        Actions(a.to_action)
                    end
                elsif arg.respond_to?(:to_action)
                    arg = arg.to_action
                    unless arg.model.kind_of?(Roby::Actions::Models::MethodAction)
                        return [arg]
                    end

                    actions_from_method_action(arg)
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
                queue = Actions(arg)
                result = []
                until queue.empty?
                    actions = Actions(queue.shift).flat_map do |action|
                        expand_action_coordination_models(action)
                    end

                    if actions.size == 1
                        result.concat(actions)
                    else
                        queue.concat(actions)
                    end
                end
                result.map { |a| a.dup.with_example_arguments }
            end

            # Like {#AtomicActions} but filters out actions that cannot be
            # handled by the bulk assertions, and returns them
            #
            # @param [Array,Action] arg the action that is expanded
            # @param [Array<Roby::Actions::Action>] actions that
            #   should be ignored. Actions are compared on the basis of their
            #   model (arguments do not count)
            def BulkAssertAtomicActions(arg, exclude: [])
                exclude = ActionModels(exclude)
                skipped_actions = []
                actions = AtomicActions(arg).map do |action|
                    if exclude.include?(action.model)
                        nil
                    elsif !action.kind_of?(Actions::Action) &&
                          action.has_missing_required_arg?
                        skipped_actions << action
                        nil
                    else
                        action
                    end
                end.compact
                skipped_actions.delete_if do |skipped_action|
                    actions.any? { |action| action.model == skipped_action.model }
                end
                [actions, skipped_actions]
            end

            # Tests that one or many syskit definitions are self-contained
            #
            # When it is part of a profile, a definition is self-contained if it only
            # contains concrete component models or tags of said profile
            #
            # Note that it is a really good idea to maintain this property. No.
            # Seriously. Keep it in your profile tests.
            #
            # When resolving actions that are not directly defined from profile
            # definitions, the method will attempte to resolve method action by
            # calling them. If there is a problem, pass the action model to the
            # `exclude` argument.
            #
            # In particular, in the presence of action methods with required
            # arguments, run one assert first with the action method excluded and
            # another with that action and sample arguments.
            #
            # @param action_or_profile if an action interface or profile, test all
            #   definitions that are reachable from it. In the case of action interfaces,
            #   this means looking into method actions and action state machines.
            def assert_is_self_contained(
                action_or_profile = subject_syskit_model,
                message: "%s is not self contained", exclude: [], **instanciate_options
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: #{skip}, "\
                          "probably because of required arguments. Pass the action to "\
                          "the 'exclude' option of #{__method__}, and add a separate "\
                          "assertion test with the arguments added explicitly"
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
            # When resolving actions that are not directly defined from profile
            # definitions, the method will attempte to resolve method action by
            # calling them. If there is a problem, pass the action model to the
            # `exclude` argument.
            #
            # In particular, in the presence of action methods with required
            # arguments, run one assert first with the action method excluded and
            # another with that action and sample arguments.
            #
            # @param action_or_profile if an action interface or profile, test all
            #   definitions that are reachable from it. In the case of action interfaces,
            #   this means looking into method actions and action state machines.
            # @param together_with test that each single action in `action_or_profile`
            #   can be instanciated when all actions in `together_with` are instanciated
            #   at the same time. This can be used if the former depend on the presence
            #   of the latter, or if you want to test against conflicts.
            def assert_can_instanciate(
                action_or_profile = subject_syskit_model,
                exclude: [], together_with: []
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: #{skip}, "\
                          "probably because of required arguments. Pass the action to "\
                          "the 'exclude' option of #{__method__}, and add a separate "\
                          "assertion test with the arguments added explicitly"
                end

                together_with =
                    validate_actions(together_with, exclude: exclude) do |skip|
                        flunk "could not validate some non-Syskit actions given to "\
                              "`together_with` in #{__method__}: #{skip}, "\
                              "probably because of "\
                              "missing arguments. If you are passing a profile or "\
                              "action interface and do not require to test against "\
                              "that particular action, pass it to the 'exclude' argument"
                    end

                actions.each do |action|
                    assert_can_instanciate_together(action, *together_with)
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
                syskit_run_deploy_in_bulk(
                    actions, compute_policies: false, compute_deployments: false
                )
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(actions, e), e.message, e.backtrace
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
            def expand_action_coordination_models(action)
                return [action] unless action.model.respond_to?(:coordination_model)

                expand_coordination_model(action.model.coordination_model)
            end

            def expand_coordination_model(coordination_model)
                coordination_model.each_task.flat_map do |coordination_task|
                    if coordination_task.respond_to?(:action)
                        expand_action_coordination_models(coordination_task.action)
                    end
                end.compact
            end

            # @api private
            #
            # Given an action, returns the list of atomic actions it refers to
            def expand_task_coordination_models(task)
                task.each_coordination_object.flat_map do |c|
                    expand_coordination_model(c.model)
                end
            end

            # Tests that the following syskit-generated actions can be deployed,
            # that is they result in a valid, non-abstract network whose all
            # components have a deployment
            #
            # When resolving actions that are not directly defined from profile
            # definitions, the method will attempte to resolve method action by
            # calling them. If there is a problem, pass the action model to the
            # `exclude` argument.
            #
            # In particular, in the presence of action methods with required
            # arguments, run one assert first with the action method excluded and
            # another with that action and sample arguments.
            #
            # @param action_or_profile if an action interface or profile, test all
            #   definitions that are reachable from it. In the case of action interfaces,
            #   this means looking into method actions and action state machines.
            # @param together_with test that each single action in `action_or_profile`
            #   can be instanciated when all actions in `together_with` are instanciated
            #   at the same time. This can be used if the former depend on the presence
            #   of the latter, or if you want to test against conflicts.
            def assert_can_deploy(
                action_or_profile = subject_syskit_model,
                exclude: [], together_with: []
            )
                actions = validate_actions(action_or_profile, exclude: exclude) do |skip|
                    flunk "could not validate some non-Syskit actions: #{skip}, "\
                          "probably because of required arguments. Pass the action to "\
                          "the 'exclude' option of #{__method__}, and add a separate "\
                          "assertion test with the arguments added explicitly"
                end

                together_with =
                    validate_actions(together_with, exclude: exclude) do |skip|
                        flunk "could not validate some non-Syskit actions given to "\
                            "`together_with` in #{__method__}: #{skip}, "\
                            "probably because of "\
                            "missing arguments. If you are passing a profile or action "\
                            "interface and do not require to test against that "\
                            "particular action, pass it to the 'exclude' argument"
                    end

                actions.each do |action|
                    assert_can_deploy_together(action, *together_with)
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
                syskit_run_deploy_in_bulk(
                    actions, compute_policies: true, compute_deployments: true
                )
            rescue Minitest::Assertion, StandardError => e
                raise ProfileAssertionFailed.new(actions, e), e.message, e.backtrace
            end

            def syskit_run_deploy_in_bulk(
                actions, compute_policies:, compute_deployments:
            )
                actions = subject_syskit_model if actions.empty?
                self.assertions += 1
                atomic_actions = actions.map { AtomicActions(_1) }
                ProfileAssertions.each_combination(*atomic_actions) do |test_actions|
                    t = syskit_deploy(
                        *test_actions.map(&:with_example_arguments),
                        compute_policies: compute_policies,
                        compute_deployments: compute_deployments
                    )
                    Array(t).each { plan.unmark_mission_task(_1) }
                    expect_execution.garbage_collect(true).to_run
                end
            end

            def self.each_combination(*arrays)
                return enum_for(__method__, *arrays) unless block_given?

                enumerators = arrays.map(&:each)
                i = 0
                values = []
                loop do
                    values[i] = enumerators[i].next
                    if i == enumerators.size - 1
                        yield values.dup
                    else
                        i += 1
                    end
                rescue StopIteration
                    return if i == 0

                    enumerators[i] = arrays[i].each
                    i -= 1
                end
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
                raise ProfileAssertionFailed.new(actions, e), e.message, e.backtrace
            end

            # Spec-style call for {#assert_can_configure_together}
            def can_configure_together(*actions)
                assert_can_configure_together(*actions)
            end

            # @api private
            def validate_actions(action_or_profile, exclude: [])
                actions, skipped =
                    BulkAssertAtomicActions(action_or_profile, exclude: exclude)

                unless skipped.empty?
                    action_names = "'#{skipped.map(&:name).sort.join("', '")}'"
                    yield(action_names)
                end

                actions
            end
        end
    end
end
