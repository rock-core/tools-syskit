require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::MergeSolver do
    include Syskit::Test::Self
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :solver
    
    before do
        @solver = Syskit::NetworkGeneration::MergeSolver.new(plan)
    end

    describe "#replacement_for" do
        it "returns the leaf object in a path in task_replacement_graph" do
            t0, t1, t2 = prepare_plan :add => 3
            solver.register_replacement(t0, t1)
            solver.register_replacement(t1, t2)
            assert_equal t2, solver.replacement_for(t0)
        end
        it "returns the given task if it has no child in the graph" do
            t0 = prepare_plan :add => 1
            assert_equal t0, solver.replacement_for(t0)
        end
        it "can resolve the same task twice and takes into accunt modifications in the replacement graph" do
            t0, t1, t2 = prepare_plan :add => 3
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
        it "returns true for compositions without children" do
            plan.add(c0 = simple_composition_model.new)
            plan.add(c1 = simple_composition_model.new)
            assert solver.resolve_single_merge(c0, c1)
        end
        it "returns true for compositions that have the same children" do
            plan.add(t = simple_component_model.new)
            plan.add(c0 = simple_composition_model.new)
            c0.depends_on(t)
            plan.add(c1 = simple_composition_model.new)
            c1.depends_on(t)
            assert solver.resolve_single_merge(c0, c1)
        end
        it "returns false for compositions that have different children" do
            plan.add(t0 = simple_component_model.new)
            plan.add(c0 = simple_composition_model.new)
            plan.add(t1 = simple_component_model.new)
            plan.add(c1 = simple_composition_model.new)
            c0.depends_on(t0, :role => 'child')
            c1.depends_on(t1, :role => 'child')
            assert_same false, solver.resolve_single_merge(c0, c1)
        end
        it "returns false for compositions that have the same child task but in different roles" do
            plan.add(t = simple_component_model.new)
            plan.add(c0 = simple_composition_model.new)
            c0.depends_on(t, :role => 'child0')
            plan.add(c1 = simple_composition_model.new)
            c1.depends_on(t, :role => 'child1')
            assert_same false, solver.resolve_single_merge(c0, c1)
        end
        it "returns false for tasks that have execution agents" do
            plan.add(t1 = simple_component_model.new)
            plan.add(t2 = simple_composition_model.new)
            flexmock(t1).should_receive(:execution_agent).and_return(true)
            assert_same false, solver.resolve_single_merge(t1, t2)
            assert_same false, solver.resolve_single_merge(t2, t1)
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
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            assert_equal [], solver.resolve_input_matching(task, task)
        end
        it "should not check for multiplexing ports for ports that do match" do
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            task_model.should_receive(:find_input_port).never
            solver.resolve_input_matching(task, task)
        end
        it "should return nil if the source port name is different" do
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            target_task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src, 'other_src_port', 'sink_port', Hash.new).
                mock
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should return nil if the policies are different" do
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src, 'src_port', 'sink_port', target_policy = flexmock(:empty? => false)).
                mock
            flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil).once
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should call the task model with the input port name to get the port model if connections mismatch" do
            task_model.should_receive(:find_input_port).with('sink_port').once.and_return(port_model)
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(target_src = Object.new, 'src_port', 'sink_port', target_policy = flexmock(:empty? => false)).
                mock
            flexmock(Syskit).should_receive(:update_connection_policy).with(policy, target_policy).and_return(nil).once
            assert !solver.resolve_input_matching(task, target_task)
        end
        it "should return the mismatching connection if the source port task is different" do
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            target_task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(target_src = Object.new, 'src_port', 'sink_port', Hash.new).
                mock
            assert_equal [["sink_port", "src_port", src, target_src]], solver.resolve_input_matching(task, target_task)
        end
        it "should return nil if the source port tasks are different and the policies are not compatible" do
            task = flexmock(:model => task_model).
                should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy = flexmock(:empty? => false)).
                mock
            target_task = flexmock(:model => task_model).
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
                task = flexmock(:model => task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(:model => task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src, 'src_port', 'sink_port', target_policy).
                    mock
                assert !solver.resolve_input_matching(task, target_task)
            end
            it "should return an empty array for connections from different ports regardless of the connection policy" do
                task = flexmock(:model => task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(:model => task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src, 'other_src_port', 'sink_port', target_policy).
                    mock
                assert_equal [], solver.resolve_input_matching(task, target_task)
            end
            it "should return an empty array for connections from different tasks regardless of the connection policy" do
                task = flexmock(:model => task_model).
                    should_receive(:each_concrete_input_connection).and_yield(src = Object.new, 'src_port', 'sink_port', policy).
                    mock
                target_task = flexmock(:model => task_model).
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
            @task        = Object.new
            @merged_task = Object.new
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
            merge_solver.process_possible_cycles(BGL::Graph.new, [[task, merged_task]])
        end
        it "should not process cycles for which the base tasks can not merge" do
            merge_solver.should_receive(:resolve_single_merge).
                once.and_return(false)
            merge_solver.should_receive(:resolve_cycle_candidate).
                never
            merge_solver.process_possible_cycles(BGL::Graph.new, [[task, merged_task]])
        end
        it "stops if new direct merges are found when preprocessing the possible_cycles graph" do
            task2, merged_task2 = Object.new, Object.new
            merge_solver.should_receive(:resolve_single_merge)
            merge_solver.should_receive(:resolve_cycle_candidate).never
            merge_solver.process_possible_cycles(flexmock(:link => nil, :linked? => false, :empty? => false),
                            [[task, merged_task], [task2, merged_task2]])
        end
        it "stops at the first merged cycle and returns the unprocessed ones" do
            task2, merged_task2 = Object.new, Object.new
            merge_solver.should_receive(:resolve_single_merge).
                and_return(nil)
            merge_solver.should_receive(:resolve_cycle_candidate).
                once.and_return(true)
            result = merge_solver.process_possible_cycles(flexmock(:link => nil, :linked? => false, :empty? => true),
                            [[task, merged_task], [task2, merged_task2]])
            assert_equal [[task2, merged_task2]].to_set, result.to_set
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
            @task_model = flexmock(:fullfilled_model => flexmock)
            @task, @target_task = flexmock('task', :model => task_model), flexmock('target_task', :model => task_model)
        end

        it "returns an empty graph if given an empty set" do
            graph, cycles = solver.direct_merge_mappings([])
            assert graph.empty?
            assert cycles.empty?
        end
        it "considers non-specialized versions of a specialized model as valid candidates" do
            task_model = Syskit::TaskContext.new_submodel
            plan.add(non_specialized = task_model.new)
            plan.add(specialized = task_model.new)
            specialized.specialize
            flexmock(non_specialized).should_receive(:can_merge?).with(specialized).once
            flexmock(specialized).should_receive(:can_merge?).with(non_specialized).once
            solver.direct_merge_mappings([non_specialized, specialized].to_value_set)
        end
        it "adds an edge for every merge candidate for which resolve_single_merge return true" do
            flexmock(plan).should_receive(:find_local_tasks).with(task_model.fullfilled_model).
                and_return([target_task])
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(true)
            graph, cycles = solver.direct_merge_mappings([task, target_task].to_value_set)
            assert graph.linked?(target_task, task)
            assert cycles.empty?
        end
        it "adds the merge candidates for which resolve_single_merge return nil to the cycle candidates" do
            flexmock(plan).should_receive(:find_local_tasks).with(task_model.fullfilled_model).
                and_return([target_task])
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(nil)
            graph, cycles = solver.direct_merge_mappings([task, target_task].to_value_set)
            assert !graph.linked?(target_task, task)
            assert_equal [[task, target_task]], cycles
        end
        it "does not take into account possible candidates that are not in the provided set" do
            flexmock(plan).should_receive(:find_local_tasks).with(task_model.fullfilled_model).
                and_return([target_task])
            flexmock(solver).should_receive(:resolve_single_merge).with(task, target_task).and_return(true)
            graph, cycles = solver.direct_merge_mappings([task].to_value_set)
            assert graph.empty?
            assert cycles.empty?
        end
    end

    describe "#break_parent_child_cycles" do
        attr_reader :task, :target_task, :merge_graph
        before do
            @merge_graph = BGL::Graph.new
            @task, @target_task = flexmock(Object.new), flexmock(Object.new)
            task.extend BGL::Vertex
            target_task.extend BGL::Vertex
            merge_graph.link(target_task, task, nil)
        end

        it "removes the parent>child edge if the child is a better merge candidate" do
            merge_graph.link(task, target_task, nil)
            flexmock(solver).should_receive(:merge_sort_order).with(target_task, task).and_return(1)
            assert_equal [], solver.break_parent_child_cycles(merge_graph, task)
            assert !merge_graph.linked?(target_task, task)
            assert merge_graph.linked?(task, target_task)
        end
        it "removes the child>parent edge if the parent is a better merge candidate" do
            merge_graph.link(task, target_task, nil)
            flexmock(solver).should_receive(:merge_sort_order).with(target_task, task).and_return(-1)
            assert_equal [target_task], solver.break_parent_child_cycles(merge_graph, task)
            assert merge_graph.linked?(target_task, task)
            assert !merge_graph.linked?(task, target_task)
        end
        it "does nothing if the merge sort order is undecided" do
            merge_graph.link(task, target_task, nil)
            flexmock(solver).should_receive(:merge_sort_order).with(target_task, task).and_return(nil)
            assert_equal [target_task], solver.break_parent_child_cycles(merge_graph, task)
            assert merge_graph.linked?(target_task, task)
            assert merge_graph.linked?(task, target_task)
        end
        it "does nothing if there is no direct cycle" do
            assert_equal [target_task], solver.break_parent_child_cycles(merge_graph, task)
            assert merge_graph.linked?(target_task, task)
            assert !merge_graph.linked?(task, target_task)
        end
    end

    describe "#resolve_ambiguities_using_sort_order" do
        attr_reader :task, :targets, :merge_graph
        before do
            @merge_graph = BGL::Graph.new
            @task = flexmock(Object.new)
            task.extend BGL::Vertex
            @targets = (1..4).map { flexmock(Object.new) }
            targets.each do |t|
                t.extend BGL::Vertex
                merge_graph.link(t, task, nil)
            end
        end

        it "should not change anything if only one parent is given" do
            flexmock(merge_graph).should_receive(:unlink).never
            solver.resolve_ambiguities_using_sort_order(merge_graph, task, targets[0, 1])
        end
        it "should remove a task that is better w.r.t. merge_sort_order with the best task last" do
            flexmock(solver).should_receive(:merge_sort_order).with(targets[0], targets[1]).and_return(1)
            flexmock(solver).should_receive(:merge_sort_order).with(targets[1], targets[0]).and_return(-1)
            flexmock(solver).should_receive(:merge_sort_order)
            flexmock(merge_graph).should_receive(:unlink).with(targets[0], task).once
            assert_equal targets[1, 3], solver.resolve_ambiguities_using_sort_order(merge_graph, task, targets)
        end
        it "should remove a task that is better w.r.t. merge_sort_order with the best task first" do
            flexmock(solver).should_receive(:merge_sort_order).with(targets[0], targets[1]).and_return(1)
            flexmock(solver).should_receive(:merge_sort_order).with(targets[1], targets[0]).and_return(-1)
            flexmock(solver).should_receive(:merge_sort_order)
            flexmock(merge_graph).should_receive(:unlink).with(targets[0], task).once
            assert_equal targets[1, 3].reverse, solver.resolve_ambiguities_using_sort_order(merge_graph, task, targets.reverse)
        end
    end

    describe "#merge_prepare" do
        attr_reader :task, :targets, :merge_graph
        before do
            @merge_graph = BGL::Graph.new
            @task = flexmock(Object.new)
            task.extend BGL::Vertex
            @targets = (1..4).map { flexmock(Object.new) }
            targets.each do |t|
                t.extend BGL::Vertex
                merge_graph.link(t, task, nil)
            end
        end

        it "resolves simple ambiguous structures" do
            ([task] + targets).each do |t|
                flexmock(solver).should_receive(:break_parent_child_cycles).once.
                    with(merge_graph, t).and_return(t_parents = flexmock(:size => 5))
                flexmock(solver).should_receive(:resolve_ambiguities_using_sort_order).once.
                    with(merge_graph, t, t_parents).and_return([])
            end
            solver.merge_prepare(merge_graph)
        end

        it "does not return the vertices without parents" do
            flexmock(solver).should_receive(:break_parent_child_cycles).and_return([])
            one, ambiguous, cycles = solver.merge_prepare(merge_graph)
            assert (one | ambiguous | cycles).empty?
        end

        it "returns the vertices with a single parent in the one_parent set" do
            flexmock(solver).should_receive(:break_parent_child_cycles).once.
                with(merge_graph, task).and_return([1])
            flexmock(solver).should_receive(:break_parent_child_cycles).and_return([])
            one, ambiguous, cycles = solver.merge_prepare(merge_graph)
            assert (ambiguous|cycles).empty?
            assert_equal [task], one.to_a
        end

        it "returns the vertices that have a cycle with their parent in the cycle set, regardless of ambiguity" do
            flexmock(solver).should_receive(:break_parent_child_cycles).once.
                with(merge_graph, task).and_return([1, 2])
            flexmock(solver).should_receive(:break_parent_child_cycles).and_return([])
            flexmock(solver).should_receive(:resolve_ambiguities_using_sort_order).once.
                and_return([1, 2])
            flexmock(merge_graph).should_receive(:reachable?).with(task, 1).and_return(true)
            flexmock(merge_graph).should_receive(:reachable?).with(task, 2).and_return(false)
            one, ambiguous, cycles = solver.merge_prepare(merge_graph)
            assert (one|ambiguous).empty?
            assert_equal [task], cycles.to_a
        end

        it "returns the vertices with multiple parents in the ambiguous set" do
            flexmock(solver).should_receive(:break_parent_child_cycles).once.
                with(merge_graph, task).and_return([1, 2, 3])
            flexmock(solver).should_receive(:break_parent_child_cycles).and_return([])
            flexmock(solver).should_receive(:resolve_ambiguities_using_sort_order).once.
                with(merge_graph, task, [1, 2, 3]).and_return([1, 2, 3])
            one, ambiguous, cycles = solver.merge_prepare(merge_graph)
            assert (one|cycles).empty?
            assert_equal [task], ambiguous.to_a
        end
    end

    describe "#update_merge_graph_neighborhood" do
        attr_reader :merge_graph, :parent, :child, :merge_solver
        before do
            @merge_solver = flexmock(Syskit::NetworkGeneration::MergeSolver.new(plan))
            vertex_t = Class.new { include BGL::Vertex }
            @merge_graph = BGL::Graph.new
            @parent = vertex_t.new
            @child  = vertex_t.new
            merge_graph.link(parent, child, nil)
        end
        it "removes links from the merge graph for target's children that are not valid anymore" do
            merge_solver.should_receive(:resolve_single_merge).with(parent, child).and_return(false)
            merge_solver.update_merge_graph_neighborhood(merge_graph, parent)
            assert !merge_graph.linked?(parent, child)
        end
        it "removes links from the merge graph for parent's children that are not valid anymore" do
            merge_solver.should_receive(:resolve_single_merge).with(parent, child).and_return(false)
            merge_solver.update_merge_graph_neighborhood(merge_graph, child)
            assert !merge_graph.linked?(parent, child)
        end
    end
end
