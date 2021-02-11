# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::Models::CompositionChild do
    describe "#try_resolve_and_bind_child" do
        it "returns the composition child if it exists" do
            task_m = Syskit::Component.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "task"
            plan.add(cmp = cmp_m.instanciate(plan))
            assert_equal cmp.task_child, cmp_m.task_child.try_resolve_and_bind_child(cmp)
        end
        it "binds the found task to the expected service if there is an expected service" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel { provides(srv_m, as: "s") }
            cmp_m  = Syskit::Composition.new_submodel do
                add srv_m, as: "task"
            end
            cmp = cmp_m.instanciate(plan,
                                    Syskit::DependencyInjectionContext.new("task" => task_m))
            assert_kind_of task_m, cmp.task_child
            assert_equal task_m.s_srv.bind(cmp.task_child),
                         cmp_m.task_child.try_resolve_and_bind_child(cmp)
        end
        it "returns nil if the composition child does not exist" do
            cmp_m = Syskit::Composition.new_submodel
            cmp = cmp_m.new
            child = Syskit::Models::CompositionChild.new(cmp_m, "task")
            assert_nil child.try_resolve_and_bind_child(cmp)
        end
        it "is available as try_resolve_child for backward-compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated).with(/try_resolve_child/).once
            cmp_m = Syskit::Composition.new_submodel
            cmp = cmp_m.new
            child = Syskit::Models::CompositionChild.new(cmp_m, "task")
            assert_nil child.try_resolve_child(cmp)
        end
    end

    describe "#try_resolve_and_bind_child_recursive" do
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::Component.new_submodel
            @task_m.provides @srv_m, as: "test"
            @cmp_m = Syskit::Composition.new_submodel
        end

        it "returns the composition child if the parent is a composition model" do
            @cmp_m.add @task_m, as: "task"
            plan.add(cmp = @cmp_m.instanciate(plan))
            assert_equal cmp.task_child,
                         @cmp_m.task_child.try_resolve_and_bind_child_recursive(cmp)
        end
        it "will resolve the children recursively" do
            child_cmp_m = Syskit::Composition.new_submodel
            @cmp_m.add child_cmp_m, as: "first"
            child_cmp_m.add @task_m, as: "second"
            plan.add(cmp = @cmp_m.instanciate(plan))
            assert_equal cmp.first_child.second_child,
                         @cmp_m.first_child.second_child.try_resolve_and_bind_child_recursive(cmp)
        end
        it "binds the found task to the expected service if there is an expected service" do
            child_cmp_m = Syskit::Composition.new_submodel
            @cmp_m.add child_cmp_m, as: "first"
            child_cmp_m.add @srv_m, as: "second"
            plan.add(cmp = @cmp_m.use("first.second" => @task_m).instanciate(plan))
            assert_equal cmp.first_child.second_child.test_srv,
                         @cmp_m.first_child.second_child.try_resolve_and_bind_child_recursive(cmp)
        end
        it "returns nil if the composition child does not exist" do
            child_cmp_m = Syskit::Composition.new_submodel
            @cmp_m.add child_cmp_m, as: "first"
            child_cmp_m.add @srv_m, as: "second"
            plan.add(cmp = @cmp_m.instanciate(plan))
            task = cmp.first_child.second_child
            cmp.remove_child(cmp.first_child)
            assert_nil @cmp_m.first_child.second_child
                             .try_resolve_and_bind_child_recursive(cmp)
        end
        it "is available as try_resolve_child_recursive for backward-compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated)
                          .with(/try_resolve_child_recursive/).once
            child_cmp_m = Syskit::Composition.new_submodel
            @cmp_m.add child_cmp_m, as: "first"
            child_cmp_m.add @srv_m, as: "second"
            plan.add(cmp = @cmp_m.use("first.second" => @task_m).instanciate(plan))
            assert_equal cmp.first_child.second_child.test_srv,
                         @cmp_m.first_child.second_child.try_resolve_child_recursive(cmp)
        end
    end

    describe "#resolve_and_bind_child" do
        let(:child_m) do
            task_m = Syskit::Component.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "task"
        end

        it "resolves the task with try_resolve_and_bind_child" do
            flexmock(child_m).should_receive(:try_resolve_and_bind_child)
                             .with(root = flexmock).and_return(result = flexmock)
            assert_equal result, child_m.resolve_and_bind_child(root)
        end
        it "raises ArgumentError if the task cannot be resolved" do
            flexmock(child_m).should_receive(:try_resolve_and_bind_child)
                             .with(root = flexmock).and_return(nil)
            assert_raises(ArgumentError) { child_m.resolve_and_bind_child(root) }
        end
        it "is available as resolve_child" do
            flexmock(Roby).should_receive(:warn_deprecated).with(/resolve_child/).once
            flexmock(child_m).should_receive(:resolve_and_bind_child)
                             .with(root = flexmock).and_return(result = flexmock)
            assert_equal result, child_m.resolve_child(root)
        end
    end

    describe "#resolve_and_bind_child_recursive" do
        let(:child_m) do
            task_m = Syskit::Component.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "task"
        end

        it "resolves the task with try_resolve_and_bind_child_recursive" do
            flexmock(child_m).should_receive(:try_resolve_and_bind_child_recursive)
                             .with(root = flexmock).and_return(result = flexmock)
            assert_equal result, child_m.resolve_and_bind_child_recursive(root)
        end
        it "raises ArgumentError if the task cannot be resolved" do
            flexmock(child_m).should_receive(:try_resolve_and_bind_child_recursive)
                             .with(root = flexmock).and_return(nil)
            assert_raises(ArgumentError) { child_m.resolve_and_bind_child_recursive(root) }
        end
    end

    describe "#bind" do
        before do
            @srv_m = Syskit::DataService.new_submodel(name: "srv_m")
            @cmp_m = Syskit::Composition.new_submodel(name: "cmp_m")
            @cmp_m.add @srv_m, as: "test"
            @task_m = Syskit::TaskContext.new_submodel(name: "task_m")
            @task_m.provides @srv_m, as: "test"
        end

        describe "when given a bound data service" do
            it "resolves the service if given as-is" do
                cmp = @cmp_m.use("test" => @task_m).instanciate(plan)
                test_task = cmp.test_child
                assert_equal test_task.test_srv,
                             @cmp_m.test_child.bind(test_task.test_srv)
            end

            it "rejects a different service from the right child" do
                other_srv_m = Syskit::DataService.new_submodel
                @task_m.provides other_srv_m, as: "other"

                cmp = @cmp_m.use("test" => @task_m).instanciate(plan)
                e = assert_raises(ArgumentError) do
                    @cmp_m.test_child.bind(cmp.test_child.other_srv)
                end
                assert_equal "cannot bind Syskit::Models::Placeholder<srv_m> to "\
                             "#<BoundDataService: task_m:0x.other>",
                             e.message.gsub(/0x[0-9a-f]+/, "0x")
            end
        end

        describe "when given a component" do
            it "resolves a direct parent" do
                cmp = @cmp_m.use("test" => @task_m).instanciate(plan)
                test_task = cmp.test_child
                assert_equal test_task.test_srv, @cmp_m.test_child.bind(test_task)
            end
            it "resolves recursively" do
                root_cmp_m = Syskit::Composition.new_submodel
                root_cmp_m.add @cmp_m, as: "root"
                root_cmp = root_cmp_m.use("root.test" => @task_m).instanciate(plan)
                test_task = root_cmp.root_child.test_child
                assert_equal test_task.test_srv,
                             root_cmp_m.root_child.test_child.bind(test_task)
            end
            it "does not move up to parents that are not the expected compositions" do
                plan.add(task = @task_m.new)
                other_cmp_m = Syskit::Composition.new_submodel(name: "other_cmp_m")
                plan.add(other_cmp = other_cmp_m.new)
                other_cmp.depends_on task, role: "test"
                e = assert_raises(ArgumentError) do
                    @cmp_m.test_child.bind(task)
                end
                assert_equal "cannot bind cmp_m.test_child["\
                             "Syskit::Models::Placeholder<srv_m>] to task_m:: "\
                             "it is not the child of any cmp_m composition",
                             e.message.gsub(/:0x.*:/, "::")
            end
            it "does not move up to parents when the role does not match" do
                plan.add(task = @task_m.new)
                plan.add(cmp = @cmp_m.new)
                cmp.depends_on task, role: "something_else"
                e = assert_raises(ArgumentError) do
                    @cmp_m.test_child.bind(task)
                end
                assert_equal "cannot bind cmp_m.test_child[Syskit::Models::"\
                             "Placeholder<srv_m>] to task_m:: it is the child of one "\
                             "or more cmp_m compositions, but not with the role 'test'",
                             e.message.gsub(/:0x.*:/, "::")
            end
        end
    end

    describe "#connect_ports" do
        it "refuses to connect ports from different models" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, as: "test" }
            c1_m = Syskit::Composition.new_submodel { add srv_m, as: "test" }
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports c1_m.test_child, {}
            end
        end
        it "gives a proper error if the connected-to object is not a composition child" do
            srv_m = Syskit::DataService.new_submodel
            c0_m = Syskit::Composition.new_submodel { add srv_m, as: "test" }
            other = flexmock
            assert_raises(ArgumentError) do
                c0_m.test_child.connect_ports other, {}
            end
        end
    end

    describe "#connect_to" do
        it "can connect to a specific service on the output side" do
            srv_in_m = Syskit::DataService.new_submodel do
                input_port "in", "/double"
            end
            task_in_m = Syskit::TaskContext.new_submodel do
                input_port "in0", "/double"
                input_port "in1", "/double"
                provides srv_in_m, as: "test", "in" => "in0"
            end
            srv_out_m = Syskit::DataService.new_submodel do
                output_port "out", "/double"
            end
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_out_m, as: "out"
            cmp_m.add task_in_m, as: "in"
            cmp_m.out_child.connect_to cmp_m.in_child.test_srv

            expected = Hash[
                %w[out in] => { %w[out in0] => {} }
            ]
            assert_equal expected, cmp_m.connections
        end
        it "can connect from a specific service on the input side" do
            srv_in_m = Syskit::DataService.new_submodel do
                input_port "in", "/double"
            end
            srv_out_m = Syskit::DataService.new_submodel do
                output_port "out", "/double"
            end
            task_out_m = Syskit::TaskContext.new_submodel do
                output_port "out0", "/double"
                output_port "out1", "/double"
                provides srv_out_m, as: "test", "out" => "out0"
            end
            cmp_m = Syskit::Composition.new_submodel do
                add srv_in_m, as: "in"
                add task_out_m, as: "out"
                out_child.test_srv.connect_to in_child
            end

            expected = Hash[
                %w[out in] => { %w[out0 in] => {} }
            ]
            assert_equal expected, cmp_m.connections
        end
    end

    describe "#bind" do
        it "should resolve services based on the initial selection" do
            srv_m = Syskit::DataService.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: "test"
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test0"
            task_m.provides srv_m, as: "test1"
            cmp = cmp_m.use("test" => task_m.test0_srv).instanciate(plan)
            assert_equal cmp.test_child.test0_srv, cmp_m.test_child.bind(cmp.test_child)
        end
        it "should be able to resolve child-of-child" do
            srv_m = Syskit::DataService.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            child_cmp_m = Syskit::Composition.new_submodel
            cmp_m.add child_cmp_m, as: "test"
            child_cmp_m.add srv_m, as: "test"
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test0"
            task_m.provides srv_m, as: "test1"
            cmp = cmp_m.use("test" => child_cmp_m.use("test" => task_m.test0_srv)).instanciate(plan)
            assert_equal cmp.test_child.test_child.test0_srv, cmp_m.test_child.test_child.bind(cmp.test_child.test_child)
        end
    end

    describe "as hash keys" do
        it "is not the same than another child with the same model" do
            composition_m = Syskit::Composition.new_submodel
            srv_m = Syskit::DataService.new_submodel
            test1 = composition_m.add srv_m, as: "test1"
            test2 = composition_m.add srv_m, as: "test2"
            assert !Hash[test1 => 10].key?(test2)
        end
    end
end

describe Syskit::Models::InvalidCompositionChildPort do
    attr_reader :cmp_m
    before do
        task_m = Syskit::TaskContext.new_submodel do
            input_port "in", "/double"
            output_port "out", "/double"
        end
        @cmp_m = Syskit::Composition.new_submodel
        cmp_m.add task_m, as: "test"
    end

    it "can be pretty-printed" do
        e = Syskit::Models::InvalidCompositionChildPort.new(cmp_m, "test", "bla")
        PP.pp(e, "".dup)
    end
end
