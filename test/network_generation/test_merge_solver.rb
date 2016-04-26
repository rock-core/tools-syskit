require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::MergeSolver do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :solver
    
    before do
        @solver = Syskit::NetworkGeneration::MergeSolver.new(plan)
    end

    describe "#replacement_for" do
        it "returns the leaf object in a path in task_replacement_graph" do
            t0, t1, t2 = prepare_plan add: 3
            solver.register_replacement(t0, t1)
            solver.register_replacement(t1, t2)
            assert_equal t2, solver.replacement_for(t0)
        end
        it "returns the given task if it has no child in the graph" do
            t0 = prepare_plan add: 1
            assert_equal t0, solver.replacement_for(t0)
        end
        it "can resolve the same task twice and takes into accunt modifications in the replacement graph" do
            t0, t1, t2 = prepare_plan add: 3
            solver.register_replacement(t0, t1)
            assert_equal t1, solver.replacement_for(t0)
            solver.register_replacement(t1, t2)
            assert_equal t2, solver.replacement_for(t0)
        end
    end

    describe "#may_merge_task_contexts?" do
        before do
            create_simple_composition_model
        end

        it "should return false if task#can_merge?(target) returns false" do
            task = flexmock(Syskit::Component.new)
            target_task = flexmock(Syskit::Component.new)
            target_task.should_receive(:can_merge?).with(task).and_return(false).once
            assert !solver.may_merge_task_contexts?(task, target_task)
        end
        it "returns false for tasks that have execution agents" do
            plan.add(t1 = simple_component_model.new)
            plan.add(t2 = simple_composition_model.new)
            flexmock(t1).should_receive(:execution_agent).and_return(true)
            assert !solver.may_merge_task_contexts?(t1, t2)
            assert !solver.may_merge_task_contexts?(t2, t1)
        end
    end

    describe "may_merge_compositions?" do
        attr_reader :task_m, :cmp_m
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @cmp_m  = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: 'child'
        end

        it "returns true for compositions without children" do
            plan.add(c0 = cmp_m.new)
            plan.add(c1 = cmp_m.new)
            assert solver.may_merge_compositions?(c0, c1)
        end
        it "returns true for compositions that have the same children" do
            plan.add(t = task_m.new)
            plan.add(c0 = cmp_m.new)
            c0.depends_on(t, role: 'child')
            plan.add(c1 = cmp_m.new)
            c1.depends_on(t, role: 'child')
            assert solver.may_merge_compositions?(c0, c1)
        end
        it "returns false for compositions that have different children" do
            plan.add(t0 = task_m.new)
            plan.add(c0 = cmp_m.new)
            plan.add(t1 = task_m.new)
            plan.add(c1 = cmp_m.new)
            c0.depends_on(t0, role: 'child')
            c1.depends_on(t1, role: 'child')
            assert !solver.may_merge_compositions?(c0, c1)
        end
        it "returns false for compositions that have the same children but the exported output ports differ" do
            srv_m = Syskit::DataService.new_submodel do
                output_port 'out', '/double'
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port 'out1', '/double'
                provides srv_m, as: 'test1', 'out' => 'out1'
                output_port 'out2', '/double'
                provides srv_m, as: 'test2', 'out' => 'out2'
            end
            cmp_m  = Syskit::Composition.new_submodel do
                add srv_m, as: 'test'
                export test_child.out_port
            end

            plan.add(child = task_m.new)
            cmp1 = cmp_m.use('test' => child.test1_srv).instanciate(plan)
            cmp2 = cmp_m.use('test' => child.test2_srv).instanciate(plan)

            assert !solver.may_merge_compositions?(cmp1, cmp2)
            assert !solver.may_merge_compositions?(cmp2, cmp1)
        end
        it "returns false for compositions that have the same children but the exported input ports differ" do
            srv_m = Syskit::DataService.new_submodel do
                input_port 'in', '/double'
            end
            task_m = Syskit::TaskContext.new_submodel do
                input_port 'in1', '/double'
                provides srv_m, as: 'test1', 'in' => 'in1'
                input_port 'in2', '/double'
                provides srv_m, as: 'test2', 'in' => 'in2'
            end
            cmp_m  = Syskit::Composition.new_submodel do
                add srv_m, as: 'test'
                export test_child.in_port
            end

            plan.add(child = task_m.new)
            cmp1 = cmp_m.use('test' => child.test1_srv).instanciate(plan)
            cmp2 = cmp_m.use('test' => child.test2_srv).instanciate(plan)

            assert !solver.may_merge_compositions?(cmp1, cmp2)
            assert !solver.may_merge_compositions?(cmp2, cmp1)
        end
        it "returns true for compositions that differ only on children whose role is not part of the model" do
            plan.add(child = task_m.new)
            plan.add(task  = task_m.new)
            plan.add(c0 = cmp_m.new)
            plan.add(c1 = cmp_m.new)
            c0.depends_on(child, role: 'child')
            c1.depends_on(child, role: 'child')
            c0.depends_on task
            assert solver.may_merge_compositions?(c0, c1)
            assert solver.may_merge_compositions?(c1, c0)
        end
    end
    
    describe "#resolve_input_matching" do
        attr_reader :task_model, :port_model
        before do
            @port_model = flexmock.
                should_receive(:multiplexes?).and_return(false).by_default.
                mock
            @task_model = flexmock.
                should_receive(:find_input_port).and_return(port_model).by_default.
                mock
        end

        it "should return an empty array if given the same task" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            assert_equal [], solver.resolve_input_matching(task, task)
        end
        it "should not check for multiplexing ports for ports that do match" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            task_model.should_receive(:find_input_port).never
            solver.resolve_input_matching(task, task)
        end
        it "should return nil if the source port name is different" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            target_task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src, 'other_src_port', 'sink_port', Hash.new).
                mock
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should return nil if the policies are different" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src, 'src_port', 'sink_port', target_policy = flexmock(:empty? => false)).
                mock
            flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil).once
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should call the task model with the input port name to get the port model if connections mismatch" do
            task_model.should_receive(:find_input_port).with('sink_port').once.and_return(port_model)
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(target_src = Object.new, 'src_port', 'sink_port', target_policy = flexmock(:empty? => false)).
                mock
            flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil).once
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should return the mismatching connection if the source port task is different" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            target_task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(target_src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            assert_equal [["sink_port", src, target_src]],
                solver.resolve_input_matching(task, target_task)
        end
        it "should return nil if the source port tasks are different and the policies are not compatible" do
            task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(model: task_model).
                should_receive(:each_concrete_input_connection).and_yield(target_src = Object.new, 'src_port', 'sink_port', target_policy = flexmock(:empty? => false)).
                mock
            flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil).once
            assert !solver.resolve_input_matching(task, target_task)
        end
        describe "connections to multiplexing inputs" do
            attr_reader :policy, :target_policy
            before do
                port_model.should_receive(:multiplexes?).and_return(true)
                @policy = flexmock(:empty? => false)
                @target_policy = flexmock(:empty? => false)
                flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil)
            end
            it "should return nil if connections from the same port are connected with different policies" do
                task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src, 'src_port', 'sink_port', target_policy).
                    mock
                assert !solver.resolve_input_matching(task, target_task)
            end
            it "should return an empty array for connections from different ports regardless of the connection policy" do
                task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src, 'other_src_port', 'sink_port', target_policy).
                    mock
                assert_equal [], solver.resolve_input_matching(task, target_task)
            end
            it "should return an empty array for connections from different tasks regardless of the connection policy" do
                task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(model: task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src, 'other_src_port', 'sink_port', target_policy).
                    mock
                assert_equal [], solver.resolve_input_matching(task, target_task)
            end
        end
    end

    describe "functional tests" do
        describe "merging compositions" do
            attr_reader :plan, :srv_m, :task_m, :cmp_m
            before do
                @plan = Roby::Plan.new
                @srv_m = Syskit::DataService.new_submodel do
                    output_port 'out', '/double'
                end
                @task_m = Syskit::TaskContext.new_submodel do
                    output_port 'out1', '/double'
                    output_port 'out2', '/double'
                end
                task_m.provides srv_m, 'out' => 'out1', as: 'out1'
                task_m.provides srv_m, 'out' => 'out2', as: 'out2'
                @cmp_m = Syskit::Composition.new_submodel
                cmp_m.add srv_m, as: 'test'
                cmp_m.export cmp_m.test_child.out_port
            end
            it "does not merge two compositions of the same model using two different services of the same task" do
                cmp1 = cmp_m.use(task_m.out1_srv).instanciate(plan)
                cmp2 = cmp_m.use(task_m.out2_srv).instanciate(plan)
                solver = Syskit::NetworkGeneration::MergeSolver.new(plan)
                flexmock(solver).should_receive(:apply_merge_group).
                    with(->(mapping) { mapping.to_a.all? { |a, b| a.kind_of?(Syskit::TaskContext) && b.kind_of?(Syskit::TaskContext) } }).
                    pass_thru
                solver.merge_identical_tasks
                plan.clear
            end
        end
    end
end

