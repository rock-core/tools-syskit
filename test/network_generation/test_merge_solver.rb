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

    describe "#resolve_single_merge" do
        before do
            create_simple_composition_model
        end

        it "should return false if task#can_merge?(target) returns false" do
            task = flexmock(Syskit::Component.new)
            target_task = flexmock(Syskit::Component.new)
            target_task.should_receive(:can_merge?).with(task).and_return(false).once
            assert_same false, solver.resolve_single_merge(task, target_task)
        end
        it "should return false if #resolve_input_matching returns false" do
            task = flexmock(Syskit::Component.new)
            target_task = flexmock(Syskit::Component.new)
            target_task.should_receive(:can_merge?).with(task).and_return(true)
            flexmock(solver).should_receive(:resolve_input_matching).with(task, target_task).and_return(false).once
            assert_same false, solver.resolve_single_merge(task, target_task)
        end
        it "should return nil if #resolve_input_matching returns missing inputs" do
            task = flexmock(Syskit::Component.new)
            target_task = flexmock(Syskit::Component.new)
            target_task.should_receive(:can_merge?).with(task).and_return(true)
            flexmock(solver).should_receive(:resolve_input_matching).with(task, target_task).and_return([Object.new]).once
            assert_same nil, solver.resolve_single_merge(task, target_task)
        end
        it "should return true if can_merge? is true and #resolve_input_matching returns an empty set of missing inputs" do
            task = flexmock(Syskit::Component.new)
            target_task = flexmock(Syskit::Component.new)
            target_task.should_receive(:can_merge?).with(task).and_return(true)
            flexmock(solver).should_receive(:resolve_input_matching).with(task, target_task).and_return([]).once
            assert_same true, solver.resolve_single_merge(task, target_task)
        end
        it "returns false for tasks that have execution agents" do
            plan.add(t1 = simple_component_model.new)
            plan.add(t2 = simple_composition_model.new)
            flexmock(t1).should_receive(:execution_agent).and_return(true)
            assert_same false, solver.resolve_single_merge(t1, t2)
            assert_same false, solver.resolve_single_merge(t2, t1)
        end
        describe "compositions" do
            attr_reader :task_m, :cmp_m
            before do
                @task_m = Syskit::TaskContext.new_submodel
                @cmp_m  = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: 'child'
            end

            it "returns true for compositions without children" do
                plan.add(c0 = cmp_m.new)
                plan.add(c1 = cmp_m.new)
                assert solver.resolve_single_merge(c0, c1)
            end
            it "returns true for compositions that have the same children" do
                plan.add(t = task_m.new)
                plan.add(c0 = cmp_m.new)
                c0.depends_on(t, role: 'child')
                plan.add(c1 = cmp_m.new)
                c1.depends_on(t, role: 'child')
                assert solver.resolve_single_merge(c0, c1)
            end
            it "returns false for compositions that have different children" do
                plan.add(t0 = task_m.new)
                plan.add(c0 = cmp_m.new)
                plan.add(t1 = task_m.new)
                plan.add(c1 = cmp_m.new)
                c0.depends_on(t0, role: 'child')
                c1.depends_on(t1, role: 'child')
                assert_same false, solver.resolve_single_merge(c0, c1)
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

                assert_same false, solver.resolve_single_merge(cmp1, cmp2)
                assert_same false, solver.resolve_single_merge(cmp2, cmp1)
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

                assert_same false, solver.resolve_single_merge(cmp1, cmp2)
                assert_same false, solver.resolve_single_merge(cmp2, cmp1)
            end
            it "returns true for compositions that differ only on children whose role is not part of the model" do
                plan.add(child = task_m.new)
                plan.add(task  = task_m.new)
                plan.add(c0 = cmp_m.new)
                plan.add(c1 = cmp_m.new)
                c0.depends_on(child, role: 'child')
                c1.depends_on(child, role: 'child')
                c0.depends_on task
                assert_same true, solver.resolve_single_merge(c0, c1)
                assert_same true, solver.resolve_single_merge(c1, c0)
            end
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
            assert_equal [["sink_port", "src_port", src, target_src]], solver.resolve_input_matching(task, target_task)
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

    describe "#process_possible_cycles" do
        attr_reader :merge_solver, :task, :merged_task
        before do
            @merge_solver = flexmock(Syskit::NetworkGeneration::MergeSolver.new(plan))
            plan.add(@task        = Syskit::Component.new)
            plan.add(@merged_task = Syskit::Component.new)
            merge_solver.should_receive(:replacement_for).and_return { |arg| arg }.by_default
        end
        it "should apply known replacements on the tasks" do
            merge_solver.should_receive(:replacement_for).with(task).
                once.and_return(new_task = Object.new)
            merge_solver.should_receive(:replacement_for).with(merged_task).
                once.and_return(new_merged_task = Object.new)
            merge_solver.should_receive(:resolve_single_merge).with(new_task, new_merged_task).
                once.and_return(nil)
            merge_solver.should_receive(:resolve_cycle_candidate).
                with(any, new_task, new_merged_task).
                once.and_return(false)
            merge_solver.process_possible_cycles([[task, merged_task]])
        end
        it "should not process cycles for which the base tasks can not merge" do
            merge_solver.should_receive(:resolve_single_merge).
                once.and_return(false)
            merge_solver.should_receive(:resolve_cycle_candidate).
                never
            merge_solver.process_possible_cycles([[task, merged_task]])
        end
        it "raises with if new direct merges are found when preprocessing the possible_cycles graph" do
            task2, merged_task = Object.new, Object.new
            merge_solver.should_receive(:resolve_single_merge).and_return(true)
            assert_raises(Syskit::InternalError) { merge_solver.process_possible_cycles([[task, merged_task]]) }
        end
        it "stops at the first merged cycle and returns the unprocessed ones" do
            plan.add(task2 = Syskit::Component.new)
            plan.add(merged_task2 = Syskit::Component.new)
            merge_solver.should_receive(:resolve_single_merge).
                and_return(nil)
            merge_solver.should_receive(:resolve_cycle_candidate).
                once.and_return(true)
            _, remaining = merge_solver.process_possible_cycles([[task, merged_task], [task2, merged_task2]])
            assert_equal [[task2, merged_task2]].to_set, remaining.to_set
        end
    end

    describe "#resolve_cycle_candidate" do
        attr_reader :task, :target_task, :src_task, :src_target_task
        before do
            @task, @target_task = flexmock('task'), flexmock('target_task')
            @src_task, @src_target_task = flexmock('src_task'), flexmock('src_target_task')
        end

        it "looks for mismatching inputs in its arguments and returns nil if there are no chances that they will match" do
            flexmock(solver).should_receive(:resolve_input_matching).with(task, target_task).and_return(nil).once
            assert !solver.resolve_cycle_candidate([], task, target_task, Hash.new)
        end

        describe "the recursive resolution behaviour" do
            attr_reader :cycle_candidates, :initial_mappings
            before do
                @cycle_candidates = [[src_task, src_target_task]]
            end

            def setup_base_calls(initial_mappings = Hash.new)
                mappings = Hash.new
                initial_mappings.each do |t1, t2|
                    solver.update_cycle_mapping(mappings, t1, t2)
                end
                flexmock(solver).should_receive(:resolve_input_matching).once.
                    with(task, target_task).
                    and_return([['sink_port', 'src_port', src_task, src_target_task]]).
                    by_default
                flexmock(solver).should_receive(:resolve_cycle_candidate).once.
                    with(cycle_candidates, task, target_task, mappings).
                    pass_thru
                @initial_mappings = mappings
            end

            it "iterates over the mismatching inputs and calls resolve_cycle_candidate recursively on them" do
                setup_base_calls
                flexmock(solver).should_receive(:resolve_cycle_candidate).once.
                    with(cycle_candidates, src_task, src_target_task, Hash).
                    and_return(Hash.new)
                assert solver.resolve_cycle_candidate(cycle_candidates, task, target_task, Hash.new)
            end
            it "returns nil if one of the recursive call returns nil" do
                setup_base_calls
                flexmock(solver).should_receive(:resolve_cycle_candidate).once.
                    with(cycle_candidates, src_task, src_target_task, Hash).
                    and_return(nil)
                assert !solver.resolve_cycle_candidate(cycle_candidates, task, target_task, Hash.new)
            end
            it "does not try to re-resolve an already known mapping" do
                setup_base_calls(src_task => src_target_task)
                flexmock(solver).should_receive(:resolve_cycle_candidate).never.
                    with(cycle_candidates, src_task, src_target_task, Hash)
                solver.resolve_cycle_candidate(cycle_candidates, task, target_task, initial_mappings)
            end
            it "does not resolve task pairs that are not included in cycle_candidates" do
                cycle_candidates.clear
                setup_base_calls
                assert !solver.resolve_cycle_candidate(cycle_candidates, task, target_task, initial_mappings)
            end
        end
    end

    describe "#direct_merge_mappings" do
        attr_reader :task_model, :task, :target_task
        before do
            @task_model = Syskit::Component.new_submodel
            plan.add(@task = task_model.new)
            plan.add(@target_task = task_model.new)
        end

        it "returns an empty graph if given an empty set" do
            graph, cycles = solver.direct_merge_mappings([])
            assert graph.empty?
            assert cycles.empty?
        end
        it "uses the instance-level #fullfilled_model to search for candidates" do
            task_model = Syskit::TaskContext.new_submodel
            plan.add(task0 = task_model.specialize.new)
            task0.fullfilled_model = [task_model, [], Hash.new]
            plan.add(task1 = task_model.specialize.new)
            task1.fullfilled_model = [task_model, [], Hash.new]
            flexmock(task0).should_receive(:can_merge?).with(task1).once
            flexmock(task1).should_receive(:can_merge?).with(task0).once
            solver.direct_merge_mappings([task0, task1].to_set)
        end
        it "merges every merge candidate for which resolve_single_merge return true" do
            flexmock(solver).should_receive(:resolve_single_merge).with(target_task, task).and_return(false)
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(true)
            graph, cycles = solver.direct_merge_mappings([task, target_task].to_set)
            assert graph.linked?(task, target_task)
            assert cycles.empty?
        end
        it "adds the merge candidates for which resolve_single_merge return nil to the cycle candidates" do
            flexmock(solver).should_receive(:resolve_single_merge).with(target_task, task).and_return(false)
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(nil)
            graph, cycles = solver.direct_merge_mappings([task, target_task].to_set)
            assert !graph.linked?(target_task, task)
            assert_equal [[task, target_task]], cycles
        end
        it "does not take into account possible candidates that are not in the provided set" do
            plan.add(task_model.new)
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(true)
            graph, cycles = solver.direct_merge_mappings([task].to_set)
            assert graph.empty?
            assert cycles.empty?
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
                flexmock(solver).should_receive(:merge).
                    with(Syskit::TaskContext, Syskit::TaskContext).
                    pass_thru
                flexmock(solver).should_receive(:merge).
                    with(Syskit::Composition, Syskit::Composition).never
                solver.merge_identical_tasks
                plan.clear
            end
        end
    end
end

