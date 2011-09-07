module Orocos
    module RobyPlugin
        # Implementation of the algorithms needed to reduce a component network
        # to the minimal set of components that are actually needed
        #
        # This is the core of the system deployment algorithm implemented in
        # Engine
        class NetworkMergeSolver
            attr_reader :plan

	    attr_reader :task_replacement_graph

            def initialize(plan, &block)
                @plan = plan
                @merging_candidates_queries = Hash.new
		@task_replacement_graph = BGL::Graph.new

                if block_given?
                    singleton_class.class_eval do
                        define_method(:merged_tasks, &block)
                    end
                end
            end

            def replacement_for(task)
                if task.plan && task.plan != plan
                    task = plan[task]
                end
                task_replacement_graph.each_dfs(task, BGL::Graph::TREE) do |_, to, _|
                    if to.leaf?(task_replacement_graph)
                        return to
                    end
                end
                return task
            end

            def self.merge_identical_tasks(plan, &block)
                solver = NetworkMergeSolver.new(plan, &block)
                solver.merge_identical_tasks
            end

            # Result table used internally by merge_sort_order
            MERGE_SORT_TRUTH_TABLE = {
                [true, true] => nil,
                [true, false] => -1,
                [false, true] => 1,
                [false, false] => nil }

            # Will return -1 if +t1+ is a better merge candidate than +t2+ --
            # i.e. if the merge should keep t1, 1 on the contrary and nil if
            # they are not comparable.
            def merge_sort_order(t1, t2)
                model_order = (t1.class <=> t2.class)
                if model_order != 0
                    return model_order
                end

                MERGE_SORT_TRUTH_TABLE[ [!t1.finished?, !t2.finished?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.running?, !!t2.running?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.execution_agent, !!t2.execution_agent] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!t1.respond_to?(:proxied_data_services), !t2.respond_to?(:proxied_data_services)] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.fully_instanciated?, !!t2.fully_instanciated?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.transaction_proxy?, !!t2.transaction_proxy?] ]
            end

            # call-seq:
            #   direct_merge_mappings(task_set, possible_cycles) => merge_graph
            #
            # Find merge candidates and returns them as a graph
            #
            # In the graph, an edge 'a' => 'b' means that we can use a to
            # replace b, i.e. a.merge(b) is valid
            #
            # +possible_cycles+ is a set of task pairs that might be merges,
            # pending resolutio of cycles in the dataflow graph.
            def direct_merge_mappings(task_set, possible_cycles = nil)
                # In the loop, we list the possible merge candidates for that
                # task. What we are looking for are tasks that can be used to
                # replace +task+

                merge_graph = BGL::Graph.new
                for task in task_set
                    # We never replace a transaction proxy. We only use them to
                    # replace new tasks in the transaction
                    next if task.transaction_proxy?
                    # Don't do service allocation at this stage. It should be
                    # done at the specification stage already
                    next if task.kind_of?(DataServiceProxy)
                    # We can only replace a deployed task by a non deployed
                    # task if the deployed task is not running
                    next if task.execution_agent && !task.pending?

                    query = @merging_candidates_queries[task.model]
                    if !query
                        required_model = task.user_required_model
                        query = @merging_candidates_queries[task.model] = plan.find_local_tasks(required_model)
                    end
                    query.reset

                    # Get the set of candidates. We are checking if the tasks in
                    # this set can be replaced by +task+
                    candidates = query.to_value_set & task_set
                    candidates.delete(task)
                    candidates.delete_if { |t| t.kind_of?(DataServiceProxy) }
                    if candidates.empty?
                        next
                    end

                    Engine.debug do
                        candidates.each do |t|
                            Engine.debug "    RAW #{t}.merge(#{task})"
                        end
                        break
                    end

                    # Used only if +task+ is a composition and we find a merge
                    # candidate that is also a composition
                    task_children = nil

                    # This loop checks in +candidates+ for the tasks that can be
                    # merged INTO +target_task+
                    for target_task in candidates
                        # Cannot merge into target_task if it is marked as not
                        # being usable
                        if !target_task.reusable?
			    Engine.debug { "    rejecting #{target_task}.merge(#{task}) as receiver is not reusable" }
			    next
			end
                        # We can not replace a non-abstract task with an
                        # abstract one
                        if (!task.abstract? && target_task.abstract?)
			    Engine.debug { "    rejecting #{target_task}.merge(#{task}) as abstract attribute mismatches" }
			    next
			end
                        # Merges involving a deployed task can only involve a
                        # non-deployed task as well
                        if (task.execution_agent && target_task.execution_agent)
			    Engine.debug { "    rejecting #{target_task}.merge(#{task}) as deployment attribute mismatches" }
			    next
			end

                        # If both tasks are compositions, merge only if +task+
                        # has the same child set than +target+
                        if task.kind_of?(Composition) && target_task.kind_of?(Composition)
                            task_children   ||= task.merged_relations(:each_child, true, false).to_value_set
                            target_children = target_task.merged_relations(:each_child, true, false).to_value_set
                            if task_children != target_children || task_children.any? { |t| t.kind_of?(DataServiceProxy) }
			        Engine.debug { "    rejecting #{target_task}.merge(#{task}) as composition have different children" }
			        next
			    end
                        end

                        # Finally, call #can_merge?
                        can_merge = target_task.can_merge?(task)
                        if can_merge.nil?
                            # Not a direct merge, but might be a cycle
                            Engine.debug do
                                "    possible cycle merge for #{target_task}.merge(#{task})"
                            end
                            if possible_cycles
                                possible_cycles << [task, target_task]
                            end
                            next
                        elsif !can_merge
			    Engine.debug { "    rejected because #{target_task}.can_merge?(#{task}) returned false" }
                            next
                        end

                        Engine.debug do
                            "    #{target_task}.merge(#{task})"
                        end
                        merge_graph.link(target_task, task, nil)
                    end
                end
                return merge_graph
            end

            def do_merge(task, target_task, all_merges, graph)
                if task == target_task
                    raise "trying to merge a task onto itself: #{task}"
                end

                Engine.debug { "    #{task}.merge(#{target_task})" }
                if task.respond_to?(:merge)
                    task.merge(target_task)
                else
                    plan.replace_task(target_task, task)
                end
                plan.remove_object(target_task)
                graph.replace_vertex(target_task, task)
                graph.remove(target_task)
		task_replacement_graph.link(target_task, task, nil)
                all_merges[target_task] = task

                # Since we modified +task+, we now have to update the graph.
                # I.e. it is possible that some of +task+'s children cannot be
                # merged into +task+ anymore
                task_children = task.enum_for(:each_child_vertex, graph).to_a
                task_children.each do |child|
                    if !task.can_merge?(child)
                        Engine.debug { "      #{task}.merge(#{child}) is not a valid merge anymore, updating merge graph" }
                        graph.unlink(task, child)
                    end
                end
            end

            # Apply the straightforward merges
            #
            # A straightforward merge is a merge in which there is no ambiguity
            # I.e. the 'replaced' task can only be merged into a single other
            # task, and there is no cycle
            def apply_simple_merges(candidates, merges, merge_graph)
                for target_task in candidates
                    parents = target_task.enum_for(:each_parent_vertex, merge_graph).to_a
                    next if parents.size != 1
                    task = parents.first

                    do_merge(task, target_task, merges, merge_graph)
                end

                merges
            end

            # Prepare for the actual merge
            #
            # It removes direct cycles between tasks, and checks that there are
            # no "big" cycles that we can't handle.
            #
            # It returns two set of tasks: a set of task that have exactly one
            # parent, and a set of tasks that have at least two parents
            def merge_prepare(merge_graph)
                one_parent, ambiguous, cycles = ValueSet.new, ValueSet.new, ValueSet.new

                candidates = merge_graph.vertices
                while !candidates.empty?
                    target_task = candidates.shift

                    parents = target_task.enum_for(:each_parent_vertex, merge_graph).to_a
                    next if parents.empty?
                    parent_count = parents.size

                    parents.each do |parent|
                        if target_task.child_vertex?(parent, merge_graph)
                            order = merge_sort_order(parent, target_task)
                            if order == 1
                                Engine.debug do
                                    "     picking up #{target_task}.merge(#{parent}) for local cycle"
                                end
                                merge_graph.unlink(parent, target_task)
                                parent_count -= 1

                            elsif order == -1
                                Engine.debug do
                                    "     picking up #{parent}.merge(#{target_task}) for local cycle"
                                end
                                merge_graph.unlink(target_task, parent)
                            end
                        end
                    end


                    in_cycle = parents.any? do |parent|
                        merge_graph.reachable?(target_task, parent)
                    end

                    if in_cycle
                        cycles << target_task
                    elsif parent_count == 1
                        one_parent << target_task
                    elsif parent_count > 1
                        ambiguous << target_task
                    end
                end

                return one_parent, ambiguous, cycles
            end

            # Do merge allocation
            #
            # In this method, we look into the tasks for which multiple merge
            # targets exist.
            #
            # There are multiple options:
            # 
            # * there is a loop. Break it if one of the two tasks is better per
            #   the merge_sort_order order.
            # * one of the targets is a better merge, per the merge_sort_order
            #   order. Select it.
            # * it is possible to disambiguate the parents using device and
            #   task names (for deployed tasks)
            #
            # +candidates+ is a set of +target_task+ tasks that need to be
            # merged **into** other tasks. The tasks that it can be merged into
            # are encoded as the parents of +target_task+ in +merge_graph+
            #
            # I.e. what this method tries to achieve is, for each task
            # +target_task+ in +candidates+, to pick a task +parent_task+ in the
            # parents of +target_task+ in +merge_graph+ and register the merge
            # in +merges+
            #
            # It does some filtering on the possible merges and yields
            # (target_task, parent_tasks) to a given block. The block should, if
            # it can, return the set of tasks that should still be considered
            # (i.e. remove some candidates from +parent_tasks+).
            def merge_allocation(candidates, merges, merge_graph)
                leftovers = ValueSet.new

                while !candidates.empty?
                    target_task = candidates.find { true }
                    candidates.delete(target_task)

                    master_set = ValueSet.new
                    target_task.each_parent_vertex(merge_graph) do |parent|
                        # Remove from +master_set+ all tasks that are superseded
                        # by +parent+, and check at the same time if +parent+
                        # does add some information to the set
                        is_worse, is_better = false, false
                        master_set.delete_if do |t|
                            order = merge_sort_order(t, parent)
                            is_worse  ||= (order == -1)
                            is_better ||= (order == 1)
                            order == 1
                        end
                        if is_better || !is_worse
                            master_set << parent
                        end
                    end

                    if master_set.empty? # nothing to do
                    elsif master_set.size == 1
                        do_merge(master_set.find { true }, target_task, merges, merge_graph)
                    else
                        result = yield(target_task, master_set)
                        if result && result.size == 1
                            task = result.to_a.first
                            do_merge(task, target_task, merges, merge_graph)
                        else
                            leftovers << target_task
                        end
                    end
                end
                leftovers
            end

            # This tries to break cycles found in the merge graph
            def break_simple_merge_cycles(merge_graph, cycles)
                cycles = cycles.map do |task|
                    reachable = ValueSet.new
                    reachable << task
                    to_remove = Array.new
                    Engine.debug { "  from #{task}" }

                    merge_graph.each_dfs(task, BGL::Graph::ALL) do |edge_from, edge_to, _|
                        if reachable.include?(edge_to)
                            Engine.debug { "    remove #{edge_from}.merge(#{edge_to})" }
                            to_remove << [edge_from, edge_to]
                        else
                            Engine.debug { "    keep #{edge_from}.merge(#{edge_to})" }
                            reachable << edge_to
                        end
                    end

                    Engine.debug do
                        Engine.debug "    reachable:"
                        reachable.each do |t|
                            Engine.debug "      #{t}"
                        end
                        break
                    end

                    [task, reachable, to_remove]
                end
                cycles = cycles.sort_by { |_, reachable, _| -reachable.size }

                ignored = ValueSet.new
                while !cycles.empty?
                    task, reachable, to_remove = cycles.shift
                    to_remove.each do |edge_from, edge_to|
                        Engine.debug { "  removing #{edge_from}.merge(#{edge_to})" }
                        merge_graph.unlink(edge_from, edge_to)
                    end
                    ignored = ignored.merge(reachable)
                    cycles.delete_if do |task, reachable, _|
                        if ignored.include?(task)
                            ignored = ignored.merge(reachable)
                            true
                        end
                    end
                end
            end

            def display_merge_graph(title, merge_graph)
                Engine.debug "  -- #{title}"
                Engine.debug do
                    merge_graph.each_vertex do |vertex|
                        vertex.each_child_vertex(merge_graph) do |child|
                            Engine.debug "    #{vertex}.merge(#{child})"
                        end
                    end
                    break
                end
            end

            # Apply merges computed by direct_merge_mappings
            #
            # It actually takes the tasks and calls #merge according to the
            # information in +mappings+. It also updates the underlying Roby
            # plan, and the set of InstanciatedComponent instances
            def apply_merge_mappings(merge_graph)
                merges = Hash.new
                merges_size = nil

                while true
                    one_parent, ambiguous, cycles = merge_prepare(merge_graph)
                    if one_parent.empty?
                        break if cycles.empty?

                        Engine.debug "  -- Breaking simple cycles in the merge graph"
                        break_simple_merge_cycles(merge_graph, cycles)
                        next
                    end

                    Engine.debug "  -- Applying simple merges"
                    apply_simple_merges(one_parent, merges, merge_graph)
                    break if cycles.empty?
                end

                
                display_merge_graph("Merge graph after first pass", merge_graph)

                Engine.debug "  -- Applying complex merges"
                while merges.size != merges_size && !ambiguous.empty?
                    merges_size = merges.size

                    ## Now, disambiguate
                    # 0. check for compositions and children. We assume that, if
                    #    a candidate is the child of another, we should select
                    #    the highest-level one
                    ambiguous = merge_allocation(ambiguous, merges, merge_graph) do |target_task, task_set|
                        Engine.debug do
                            Engine.debug "    trying to disambiguate using dependency structure: #{target_task}"
                            task_set.each do |t|
                                Engine.debug "        => #{t}"
                            end
                            break
                        end

                        task_set.find_all do |candidate|
                            !task_set.any? do |possible_parent|
                                possible_parent != candidate &&
                                    Roby::TaskStructure::Dependency.reachable?(possible_parent, candidate)
                            end
                        end
                    end

                    # 1. use device and orogen names
                    ambiguous = merge_allocation(ambiguous, merges, merge_graph) do |target_task, task_set|
                        if !target_task.respond_to?(:each_device_name)
                            Engine.debug { "cannot disambiguate using names: #{target_task} is no device driver" }
                            next
                        end
                        device_names = target_task.each_device_name.map { |_, dev_name| Regexp.new("^#{dev_name}$") }
                        if device_names.empty?
                            Engine.debug { "cannot disambiguate using names: #{target_task} is a device driver, but it is attached to no devices" }
                            next
                        end

                        deployed = task_set.find_all(&:execution_agent)
                        if deployed.empty?
                            Engine.debug { "cannot disambiguate using names: no merge candidates of #{target_task} is deployed" }
                            next
                        end

                        Engine.debug do
                            Engine.debug "    trying to disambiguate using names: #{target_task}"
                            Engine.debug "    devices: #{device_names.join(", ")}"
                            deployed.each do |t|
                                Engine.debug "       #{t.orogen_name} #{t.execution_agent.deployment_name}"
                            end
                            break
                        end

                        task_set.find_all do |t|
                            device_names.any? do |dev_name|
                                t.orogen_name =~ dev_name ||
                                t.execution_agent.deployment_name =~ dev_name
                            end
                        end
                    end

                    # 2. use locality
                    ambiguous = merge_allocation(ambiguous, merges, merge_graph) do |target_task, task_set|
                        neighbours = ValueSet.new
                        target_task.each_concrete_input_connection do |source_task, _|
                            neighbours << source_task
                        end
                        target_task.each_concrete_output_connection do |_, _, sink_task, _|
                            neighbours << sink_task
                        end
                        if neighbours.empty?
                            next
                        end

                        Engine.debug do
                            Engine.debug "    trying to disambiguate using distance: #{target_task}"
                            task_set.each do |t|
                                Engine.debug "        => #{t}"
                            end
                            break
                        end

                        distances = task_set.map do |task|
                            [task, neighbours.map { |neighour_t| neighour_t.distance_to(task) || TaskContext::D_MAX }.min]
                        end
                        min_d = distances.min { |a, b| a[1] <=> b[1] }[1]
                        all_candidates = distances.find_all { |t, d| d == min_d }
                        if all_candidates.size == 1
                            all_candidates.map(&:first)
                        end
                    end

                    # 3. if target_task is not a device driver and possible
                    # merges have the same model, pick one randomly
                    ambiguous = merge_allocation(ambiguous, merges, merge_graph) do |target_task, task_set|
                        if !target_task.respond_to?(:each_device_name)
                            candidate = task_set.find { true }
                            if task_set.all? { |t| t.model == candidate.model }
                                Engine.debug { "randomly picking #{candidate}" }
                                [candidate]
                            end
                        end
                    end
                end

                if respond_to?(:merged_tasks)
                    merged_tasks(merges)
                end

                resulting_merge_graph = BGL::Graph.new
                merges.each do |replaced_task, task|
                    resulting_merge_graph.link(replaced_task, task, nil)
                end
                resulting_merge_graph
            end

            # Propagation step in the BFS of merge_identical_tasks
            def merge_tasks_next_step(task_set) # :nodoc:
                result = ValueSet.new
                for t in task_set
                    children = t.each_sink(false).to_value_set
                    result.merge(children) if children.size > 1
                    result.merge(t.each_parent_task.to_value_set.delete_if { |parent_task| !parent_task.kind_of?(Composition) })
                end
                result
            end

            def complete_merge_graph
                all_tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).
                    to_value_set
                direct_merge_mappings(all_tasks)
            end

            # Checks if +from+ can be merged into +to+, taking into account
            # possible dataflow cycles that might exist between these tasks
            def can_merge_cycle?(possible_cycles, from, to, mappings = Hash.new)
                # Note: we do take into account that we already called
                # #can_merge? on the from => to merge. I.e. we don't have to do
                # all the sanity checks that is already done there. Checking the
                # connections paths is enough
                mappings = mappings.merge(from => to)

                self_inputs = Hash.new
                from.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    self_inputs[sink_port] = [source_task, source_port]
                end

                to.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if !(conn = self_inputs[sink_port])
                        next
                    end

                    same_port = (conn[1] == source_port)
                    same_source = (conn[0] == source_task || mappings[conn[0]] == source_task)

                    if !same_port
                        return false
                    elsif !same_source
                        if mappings.has_key?(conn[0])
                            return false
                        elsif !possible_cycles.include?([conn[0], source_task])
                            return false
                        elsif !can_merge_cycle?(possible_cycles, conn[0], source_task, mappings)
                            return false
                        end
                    end
                end
            end

            # Merges tasks that are equivalent in the current plan
            #
            # It is a BFS that follows the data flow. I.e., it computes the set
            # of tasks that can be merged and then will look at the children of
            # these tasks and so on and so forth.
            #
            # The step is given by #merge_tasks_next_step
            def merge_identical_tasks
                Engine.debug do
                    Engine.debug ""
                    Engine.debug "----------------------------------------------------"
                    Engine.debug "Merging identical tasks"
                    break
                end

                # Get all the tasks we need to consider. That's easy,
                # they all implement the Orocos::RobyPlugin::Component model
                all_tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).
                    to_value_set

                Engine.debug do
                    Engine.debug "-- Tasks in plan"
                    all_tasks.each do |t|
                        Engine.debug "    #{t}"
                    end
                    break
                end

                # The first pass of the algorithm looks that the tasks that have
                # the same inputs, checks if they can be merged and do so if
                # they can.
                #
                # The algorithm is seeded by the tasks that already have the
                # same inputs and the ones that have no inputs. It then
                # propagates to the children of the merged tasks and so on.
                candidates = all_tasks.dup

                merged_tasks = ValueSet.new
                possible_cycles = Set.new
                while !candidates.empty?
                    merged_tasks.clear
                    possible_cycles.clear

                    while !candidates.empty?
                        Engine.debug "  -- Raw merge candidates"
                        merges = direct_merge_mappings(candidates, possible_cycles)
                        Engine.debug "     #{merges.size} vertices in merge graph"
                        Engine.debug "     #{possible_cycles.size} possible cycles"

                        if merges.empty?
                            Engine.debug "  -- Looking for merges in dataflow cycles"
                            possible_cycles = possible_cycles.to_a

                            # Resolve one cycle. As soon as we solved one, cycle in the
                            # normal procedure (resolving one task should break the
                            # cycle)
                            rejected_cycles = []
                            while !possible_cycles.empty?
                                cycle = possible_cycles.shift
                                Engine.debug { "    checking cycle #{cycle[0]}.merge(#{cycle[1]})" }

                                if !can_merge_cycle?(possible_cycles, *cycle)
                                    Engine.debug { "    cannot merge cycle #{cycle[0]}.merge(#{cycle[1]})" }
                                    rejected_cycles << cycle
                                    next
                                end

                                Engine.debug { "    found cycle merge for #{cycle[1]}.merge(#{cycle[1]})" }
                                merges.link(cycle[0], cycle[1], nil)
                                if possible_cycles.include?([cycle[1], cycle[0]])
                                    merges.link(cycle[1], cycle[0], nil)
                                end
                                break
                            end
                            possible_cycles.concat(rejected_cycles)
                        end
                        if merges.empty?
                            candidates.clear
                            break 
                        end

                        applied_merges = apply_merge_mappings(merges)
                        candidates = ValueSet.new
                        applied_merges.each_vertex do |task|
                            candidates << task if task.leaf?
                        end
                        merged_tasks.merge(candidates)

                        Engine.debug do
                            Engine.debug "  -- Merged tasks during this pass"
                            for t in candidates
                                Engine.debug "    #{t}"
                            end
                            break
                        end
                        candidates = merge_tasks_next_step(candidates)

                        possible_cycles.each do |from, to|
                            candidates << replacement_for(from)
                            candidates << replacement_for(to)
                        end
                        possible_cycles.clear

                        Engine.debug do
                            Engine.debug "  -- Candidates for next pass"
                            for t in candidates
                                Engine.debug "    #{t}"
                            end
                            break
                        end
                    end


                    Engine.debug "  -- Parents"
                    for t in merged_tasks
                        parents = t.each_parent_task.to_value_set
                        candidates.merge(parents) if parents.size > 1
                    end
                end

                Engine.debug do
                    Engine.debug "done merging identical tasks"
                    Engine.debug "----------------------------------------------------"
                    Engine.debug ""
                    break
                end
            end
        end
    end
end


