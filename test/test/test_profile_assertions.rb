# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test"

module Syskit
    module Test
        describe ProfileAssertions do
            before do
                @cmp_m = Syskit::Composition.new_submodel(name: "Cmp")
                @task_m = Syskit::TaskContext.new_submodel(name: "Task")
                @srv_m = Syskit::DataService.new_submodel(name: "Srv")
                @task_m.provides @srv_m, as: "test"
                @cmp_m.add @task_m, as: "child"
                @cmp_m.add @srv_m, as: "test"
            end

            describe "ActionModels" do
                include ProfileAssertions

                before do
                    @profile_m = Syskit::Actions::Profile.new
                    @profile_m.define "test", @cmp_m
                    @interface_m = Roby::Actions::Interface.new_submodel
                    @interface_m.use_profile @profile_m
                end

                it "resolves an instance requirements action" do
                    assert_equal [@interface_m.test_def.model],
                                 ActionModels(@interface_m.test_def)
                end

                it "resolves a method action" do
                    task_m = Roby::Task.new_submodel
                    @interface_m.class_eval do
                        describe("act").returns(task_m)
                        define_method :act do
                        end
                    end

                    assert_equal [@interface_m.act.model], ActionModels(@interface_m.act)
                end

                it "handles array of actions as argument" do
                    @interface_m.class_eval do
                        describe("act")
                        define_method(:act) {}
                    end

                    assert_equal [@interface_m.act.model, @interface_m.test_def.model],
                                 ActionModels([@interface_m.act, @interface_m.test_def])
                end

                it "resolves an action state machine" do
                    task_m = Roby::Task.new_submodel
                    @interface_m.class_eval do
                        describe("act").returns(task_m)
                        action_state_machine :act do
                            start state(task_m)
                        end
                    end

                    assert_equal [@interface_m.act.model], ActionModels(@interface_m.act)
                end
            end

            describe "Actions" do
                include ProfileAssertions

                before do
                    @profile_m = Syskit::Actions::Profile.new
                    @profile_m.define "test", @cmp_m
                    @profile_m.define "test2", @cmp_m
                    @interface_m = Roby::Actions::Interface.new_submodel
                    @interface_m.use_profile @profile_m
                end

                it "resolves an instance requirements action" do
                    assert_equal [@interface_m.test_def], Actions(@interface_m.test_def)
                end

                it "accepts an array as argument" do
                    task_m = Roby::Task.new_submodel
                    @interface_m.class_eval do
                        describe("act").returns(task_m)
                        define_method(:act) do
                            root = task_m.new
                            root.depends_on(test2_def)
                            root
                        end
                    end

                    assert_equal [@interface_m.test2_def, @interface_m.test_def],
                                 Actions([@interface_m.act, @interface_m.test_def])
                end

                it "resolves a method action that returns a task with "\
                   "a coordination model" do
                    task_m = Roby::Task.new_submodel
                    @interface_m.class_eval do
                        describe("act").returns(task_m)
                        define_method :act do
                            root = task_m.new
                            action_state_machine(root) do
                                start task(test_def)
                            end
                            root
                        end
                    end

                    assert_equal [@interface_m.test_def], Actions(@interface_m.act)
                end

                it "resolves a method action that returns a task with children "\
                   "that are itself method actions" do
                    task_m = Roby::Task.new_submodel
                    @interface_m.class_eval do
                        describe("act").returns(task_m)
                        define_method :act do
                            root = task_m.new
                            root.depends_on model.act2
                            root
                        end

                        describe("act2").returns(task_m)
                        define_method :act2 do
                            root = task_m.new
                            root.depends_on test_def
                            root
                        end
                    end

                    assert_equal [@interface_m.test_def], Actions(@interface_m.act)
                end

                it "resolves a method action that returns a task with children "\
                   "that are themselves instance requirement tasks" do
                    @interface_m.class_eval do
                        task_m = Roby::Task.new_submodel
                        describe("act").returns(task_m)
                        define_method :act do
                            root = task_m.new
                            root.depends_on test_def
                            root
                        end
                    end

                    assert_equal [@interface_m.test_def], Actions(@interface_m.act)
                end
            end

            describe "BulkAssertAtomicActions" do
                include ProfileAssertions

                before do
                    @profile_m = Syskit::Actions::Profile.new
                    @profile_m.define "test", @cmp_m
                    @interface_m = Roby::Actions::Interface.new_submodel
                    @interface_m.use_profile @profile_m
                end

                it "lists all actions that can be resolved from its argument" do
                    @interface_m.describe(:sm)
                    @interface_m.action_state_machine :sm do
                        start state(test_def)
                    end

                    assert_equal [[@interface_m.test_def], []],
                                 BulkAssertAtomicActions(@interface_m.sm)
                end

                it "excludes actions from the models listed in 'exclude'" do
                    @interface_m.describe(:sm)
                    @interface_m.action_state_machine :sm do
                        start state(test_def)
                    end

                    found, skipped = BulkAssertAtomicActions(
                        @interface_m.sm, exclude: [@interface_m.test_def]
                    )
                    assert_equal [], found
                    assert_equal [], skipped
                end

                it "reports actions that cannot be instanciated "\
                   "because of missing arguments" do
                    @interface_m.describe(:m_action).required_arg(:test, "some docs")
                    @interface_m.define_method(:m_action) do |test:|
                    end

                    found, skipped = BulkAssertAtomicActions(@interface_m.m_action)
                    assert_equal [], found
                    assert_equal [@interface_m.m_action], skipped
                end

                it "reports actions that cannot be instanciated "\
                   "because of missing arguments within a state machine" do
                    @interface_m.describe(:m_action).required_arg(:test, "some docs")
                    @interface_m.define_method(:m_action) do |test:|
                    end
                    @interface_m.describe(:sm)
                    @interface_m.action_state_machine :sm do
                        start state(m_action)
                    end

                    found, skipped = BulkAssertAtomicActions(@interface_m.sm)
                    assert_equal [], found
                    assert_equal [@interface_m.m_action], skipped
                end

                it "lets the caller exclude atomic actions" do
                    @interface_m.describe(:sm)
                    @interface_m.action_state_machine :sm do
                        start state(test_def)
                    end

                    found, skipped = BulkAssertAtomicActions(
                        @interface_m.sm, exclude: [@interface_m.sm]
                    )
                    assert_equal [@interface_m.test_def], found
                    assert_equal [], skipped
                end

                it "lets the caller exclude method actions with missing arguments" do
                    @interface_m.describe(:m_action).required_arg(:test, "")
                    @interface_m.define_method :m_action do |test:|
                    end

                    found, skipped = BulkAssertAtomicActions(
                        @interface_m.m_action, exclude: [@interface_m.m_action]
                    )
                    assert_equal [], found
                    assert_equal [], skipped
                end
            end

            describe "assert_is_self_contained" do
                include ProfileAssertions

                # Needed by ProfileAssertions
                attr_reader :subject_syskit_model

                before do
                    @test_profile = Actions::Profile.new
                    @subject_syskit_model = @test_profile
                end

                it "passes for definitions that have no services" do
                    @test_profile.define "test", @cmp_m.use(@srv_m => @task_m)
                    assert_is_self_contained(@test_profile)
                end

                it "passes for definitions whose services are represented by tags" do
                    @test_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => @test_profile.test_tag)
                    )
                    assert_is_self_contained(@test_profile)
                end

                it "fails for definitions with abstract elements that are not tags" do
                    @test_profile.define "test", @cmp_m
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_is_self_contained(@test_profile)
                    end
                    assert_match(/test_def.*is not self contained/, e.message)
                end

                it "fails for definitions that use tags from other profiles" do
                    other_profile = Actions::Profile.new
                    other_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => other_profile.test_tag)
                    )

                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_is_self_contained(@test_profile)
                    end
                    assert_match(
                        /test_def.*contains tags from another profile/,
                        e.message
                    )
                end

                it "handles plain instance requirements" do
                    @test_profile.tag "test", @srv_m
                    assert_is_self_contained(@cmp_m.use(@srv_m => @test_profile.test_tag))
                end

                it "fails if some actions are not resolvable" do
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(action = flexmock, exclude: (excluded = flexmock))
                        .and_return([[],
                                     [flexmock(name: "some"), flexmock(name: "action")]])

                    e = assert_raises(Minitest::Assertion) do
                        assert_is_self_contained(action, exclude: excluded)
                    end
                    message = "could not validate some non-Syskit actions: 'action', "\
                              "'some', probably because of required arguments. Pass "\
                              "the action to the 'exclude' option of "\
                              "assert_is_self_contained, and add a separate assertion "\
                              "test with the arguments added explicitly"
                    assert_equal message, e.message
                end
            end

            describe "assert_can_instanciate" do
                include ProfileAssertions

                # Needed by ProfileAssertions
                attr_reader :subject_syskit_model

                before do
                    @test_profile = Actions::Profile.new("TestProfile")
                    @subject_syskit_model = @test_profile
                end

                it "passes for definitions that have no services or tags" do
                    @test_profile.define "test", @cmp_m.use(@srv_m => @task_m)
                    assert_can_instanciate(@test_profile)
                end

                it "fails for definitions whose services are represented by tags" do
                    @test_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => @test_profile.test_tag)
                    )
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_instanciate(@test_profile)
                    end
                    assert_match(
                        /cannot\ find\ a\ concrete\ implementation.*
                         TestProfile.test_tag/mx, e.message
                    )
                end

                it "fails for definitions with abstract elements that are not tags" do
                    @test_profile.define "test", @cmp_m
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_instanciate(@test_profile)
                    end
                    assert_match(
                        /cannot\ find\ a\ concrete\ implementation.*
                         Models::Placeholder<Srv>/mx, e.message
                    )
                end

                it "fails for definitions that use tags from other profiles" do
                    other_profile = Actions::Profile.new("Other")
                    other_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => other_profile.test_tag)
                    )

                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_instanciate(@test_profile)
                    end
                    assert_match(
                        /cannot find a concrete implementation.*profile:Other.test_tag/m,
                        e.message
                    )
                end

                it "handles plain instance requirements" do
                    assert_can_instanciate(@cmp_m.use(@srv_m => @task_m))
                end

                it "allows deploying together with the actions or profile" do
                    @task_m.argument :bla
                    @test_profile.define "test", @cmp_m.use(@srv_m => @task_m)
                    assert_can_instanciate(
                        @test_profile, together_with: @task_m.with_arguments(bla: 9)
                    ) do
                        t = plan.find_tasks(@cmp_m).first.test_child
                        assert_equal 9, t.bla
                    end
                end

                it "fails if some actions are not resolvable" do
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(action = flexmock, exclude: (excluded = flexmock))
                        .and_return([[],
                                     [flexmock(name: "some"), flexmock(name: "action")]])

                    e = assert_raises(Minitest::Assertion) do
                        assert_can_instanciate(action, exclude: excluded)
                    end
                    message = "could not validate some non-Syskit actions: 'action', "\
                              "'some', probably because of required arguments. Pass "\
                              "the action to the 'exclude' option of "\
                              "assert_can_instanciate, and add a separate assertion "\
                              "test with the arguments added explicitly"
                    assert_equal message, e.message
                end

                it "fails if some actions in together_with are not resolvable" do
                    action, together_with, exclude = 3.times.map { flexmock }
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(action, exclude: exclude)
                        .and_return([[], []])
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(together_with, exclude: exclude)
                        .and_return([[],
                                     [flexmock(name: "some"), flexmock(name: "action")]])

                    e = assert_raises(Minitest::Assertion) do
                        assert_can_instanciate(
                            action, exclude: exclude, together_with: together_with
                        )
                    end
                    message =
                        "could not validate some non-Syskit actions given "\
                        "to `together_with` in assert_can_instanciate: 'action', "\
                        "'some', probably because of "\
                        "missing arguments. If you are passing a profile or action "\
                        "interface and do not require to test against that particular "\
                        "action, pass it to the 'exclude' argument"
                    assert_equal message, e.message
                end
            end

            describe "assert_can_deploy" do
                include ProfileAssertions

                # Needed by ProfileAssertions
                attr_reader :subject_syskit_model

                before do
                    @test_profile = Actions::Profile.new("TestProfile")
                    @deployment_m = syskit_stub_deployment_model(@task_m)
                    @subject_syskit_model = @test_profile
                end

                it "passes for definitions that refer to deployed tasks" do
                    @test_profile.use_deployment @deployment_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => @task_m)
                    )
                    assert_can_deploy(@test_profile)
                end

                it "fails for definitions that have tasks that are not deployed" do
                    @test_profile.define "test", @cmp_m.use(@srv_m => @task_m)
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_deploy(@test_profile)
                    end

                    assert_match(
                        /cannot deploy the following tasks.*Task.*child test of Cmp/m,
                        e.message
                    )
                end

                it "fails for definitions whose services are represented by tags" do
                    @test_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => @test_profile.test_tag)
                    )
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_deploy(@test_profile)
                    end
                    assert_match(
                        /cannot\ find\ a\ concrete\ implementation.*
                         TestProfile.test_tag/mx, e.message
                    )
                end

                it "fails for definitions with abstract elements that are not tags" do
                    @test_profile.define "test", @cmp_m
                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_deploy(@test_profile)
                    end
                    assert_match(
                        /cannot\ find\ a\ concrete\ implementation.*
                         Models::Placeholder<Srv>/mx, e.message
                    )
                end

                it "fails for definitions that use tags from other profiles" do
                    other_profile = Actions::Profile.new("Other")
                    other_profile.tag "test", @srv_m
                    @test_profile.define(
                        "test", @cmp_m.use(@srv_m => other_profile.test_tag)
                    )

                    e = assert_raises(ProfileAssertions::ProfileAssertionFailed) do
                        assert_can_deploy(@test_profile)
                    end
                    assert_match(
                        /cannot find a concrete implementation.*profile:Other.test_tag/m,
                        e.message
                    )
                end

                it "handles plain instance requirements" do
                    assert_can_deploy(
                        @cmp_m
                        .to_instance_requirements
                        .use_deployment(@deployment_m)
                        .use(@srv_m => @task_m)
                    )
                end

                it "allows deploying together with the actions or profile" do
                    @test_profile.define("test", @cmp_m.use(@srv_m => @task_m))
                    assert_can_deploy(
                        @test_profile.test_def,
                        together_with: @task_m.to_instance_requirements
                                              .use_deployment(@deployment_m)
                    )
                end

                it "fails if some actions are not resolvable" do
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(action = flexmock, exclude: (excluded = flexmock))
                        .and_return([[],
                                     [flexmock(name: "some"), flexmock(name: "action")]])

                    e = assert_raises(Minitest::Assertion) do
                        assert_can_deploy(action, exclude: excluded)
                    end
                    message = "could not validate some non-Syskit actions: 'action', "\
                              "'some', probably because of required arguments. Pass "\
                              "the action to the 'exclude' option of "\
                              "assert_can_deploy, and add a separate assertion "\
                              "test with the arguments added explicitly"
                    assert_equal message, e.message
                end

                it "fails if some actions in together_with are not resolvable" do
                    action, together_with, exclude = 3.times.map { flexmock }
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(action, exclude: exclude)
                        .and_return([[], []])
                    flexmock(self)
                        .should_receive(:BulkAssertAtomicActions)
                        .with(together_with, exclude: exclude)
                        .and_return([[],
                                     [flexmock(name: "some"), flexmock(name: "action")]])

                    e = assert_raises(Minitest::Assertion) do
                        assert_can_deploy(
                            action, exclude: exclude, together_with: together_with
                        )
                    end
                    message =
                        "could not validate some non-Syskit actions given "\
                        "to `together_with` in assert_can_deploy: 'action', "\
                        "'some', probably because of "\
                        "missing arguments. If you are passing a profile or action "\
                        "interface and do not require to test against that particular "\
                        "action, pass it to the 'exclude' argument"
                    assert_equal message, e.message
                end
            end
        end
    end
end
