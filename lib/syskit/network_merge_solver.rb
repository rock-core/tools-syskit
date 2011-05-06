module Orocos
    module RobyPlugin
        # Implementation of the algorithms needed to reduce a component network
        # to the minimal set of components that are actually needed
        #
        # This is the core of the system deployment algorithm implemented in
        # Engine
        class NetworkMergeSolver
            attr_reader :plan

            def initialize(plan, &block)
                @plan = plan
                @merging_candidates_queries = Hash.new

                if block_given?
                    singleton_class.class_eval do
                        define_method(:merged_tasks, &block)
                    end
                end
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
                        candidates.each do |target_task|
                            Engine.debug "    RAW #{task} => #{target_task}"
                        end
                        break
                    end

                    # Used only if +task+ is a composition and we find a merge
                    # candidate that is also a composition
                    task_children = nil

                    for target_task in candidates
                        # We can not replace a non-abstract task with an
                        # abstract one
                        next if (!task.abstract? && target_task.abstract?)
                        # Merges involving a deployed task can only involve a
                        # non-deployed task as well
                        next if (task.execution_agent && target_task.execution_agent)

                        # If both tasks are compositions, merge only if +task+
                        # has the same child set than +target+
                        if task.kind_of?(Composition) && target_task.kind_of?(Composition)
                            task_children   ||= task.merged_relations(:each_child, true, false).to_value_set
                            target_children = target_task.merged_relations(:each_child, true, false).to_value_set
                            next if task_children != target_children || task_children.any? { |t| t.kind_of?(DataServiceProxy) }
                        end

                        # Finally, call #can_merge?
                        can_merge = target_task.can_merge?(task)
                        if can_merge.nil?
                            # Not a direct merge, but might be a cycle
                            Engine.debug do
                                "    possible cycle merge for #{task} => #{target_task}"
                            end
                            if possible_cycles
                                possible_cycles << [task, target_task]
                            end
                            next
                        elsif !can_merge
                            next
                        end

                        Engine.debug do
                            "    #{task} => #{target_task}"
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

                Engine.debug { "    #{target_task} => #{task}" }
                if task.respond_to?(:merge)
                    task.merge(target_task)
                else
                    plan.replace_task(target_task, task)
                end
                plan.remove_object(target_task)
                graph.replace_vertex(target_task, task)
                graph.remove(target_task)
                all_merges[target_task] = task

                # Since we modified +task+, we now have to update the graph.
                # I.e. it is possible that some of +task+'s children cannot be
                # merged into +task+ anymore
                task_children = task.enum_for(:each_child_vertex, graph).to_a
                modified_task_children = []
                task_children.each do |child|
                    if !task.can_merge?(child)
                        Engine.debug do
                            "      #{child} => #{task} is not a valid merge anymore, updating merge graph"
                        end
                        graph.unlink(task, child)
                        modified_task_children << child
                    end
                end
                modified_task_children
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
                                    "     picking up #{parent} => #{target_task} for local cycle"
                                end
                                merge_graph.unlink(parent, target_task)
                                parent_count -= 1
                                next
                            end

                            if order == -1
                                Engine.debug do
                                    "     picking up #{target_task} => #{parent} for local cycle"
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

            def break_simple_cycles(merge_graph, cycles)
                cycles.delete_if do |task|
                    parent_removal =
                        task.enum_for(:each_parent_vertex, merge_graph).find_all do |parent|
                            cycles.include?(parent)
                        end

                    if !parent_removal.empty?
                        parent_removal.each do |removed_parent|
                            Engine.debug do
                                "    #{removed_parent} => #{task}"
                            end
                            merge_graph.unlink(removed_parent, task)
                        end
                        next(true)
                    end

                    child_removal =
                        task.enum_for(:each_child_vertex, merge_graph).find_all do |child|
                            cycles.include?(child)
                        end
                    if !child_removal.empty?
                        child_removal.each do |removed_child|
                            Engine.debug do
                                "    #{task} => #{removed_child}"
                            end
                            merge_graph.unlink(task, removed_child)
                            next(true)
                        end
                    end

                    false
                end
            end



            def display_merge_graph(title, merge_graph)
                Engine.debug "  -- #{title} (a => b merges 'a' into 'b') "
                Engine.debug do
                    merge_graph.each_vertex do |vertex|
                        vertex.each_child_vertex(merge_graph) do |child|
                            Engine.debug "    #{child} => #{vertex}"
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

                        Engine.debug "  -- Breaking simple cycles (a => b removes the merge of 'a' into 'b') "
                        break_simple_cycles(merge_graph, cycles)
                        next
                    end

                    Engine.debug "  -- Applying simple merges (a => b merges 'a' into 'b') "
                    apply_simple_merges(one_parent, merges, merge_graph)
                    break if cycles.empty?
                end

                
                display_merge_graph("Merge graph after first pass", merge_graph)

                Engine.debug "  -- Applying complex merges (a => b merges 'a' into 'b') "
                while merges.size != merges_size && !ambiguous.empty?
                    merges_size = merges.size

                    ## Now, disambiguate
                    # 0. check for compositions and children. We assume that, if
                    #    a candidate is the child of another, we should select
                    #    the highest-level one
                    ambiguous = merge_allocation(ambiguous, merges, merge_graph) do |target_task, task_set|
                        Engine.debug do
                            Engine.debug "    trying to disambiguate using dependency structure: #{target_task}"
                            task_set.each do |task|
                                Engine.debug "        => #{task}"
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
                            Engine.debug do
                                "cannot disambiguate using names: #{target_task} is no device driver"
                            end
                            next
                        end
                        device_names = target_task.each_device_name.map { |_, dev_name| Regexp.new("^#{dev_name}$") }
                        if device_names.empty?
                            Engine.debug do
                                "cannot disambiguate using names: #{target_task} is a device driver, but it is attached to no devices"
                            end
                            next
                        end

                        deployed = task_set.find_all(&:execution_agent)
                        if deployed.empty?
                            Engine.debug do
                                "cannot disambiguate using names: no merge candidates of #{target_task} is deployed"
                            end
                            next
                        end

                        Engine.debug do
                            Engine.debug "    trying to disambiguate using names: #{target_task}"
                            Engine.debug "    devices: #{device_names.join(", ")}"
                            deployed.each do |task|
                                Engine.debug "       #{task.orogen_name} #{task.execution_agent.deployment_name}"
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
                            task_set.each do |task|
                                Engine.debug "        => #{task}"
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
                merges.values.to_value_set
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
                        Engine.debug "  -- Raw merge candidates (a => b merges 'a' into 'b')"
                        merges = direct_merge_mappings(candidates, possible_cycles)

                        if merges.empty?
                            possible_cycles = possible_cycles.to_a

                            # Resolve one cycle. As soon as we solved one, cycle in the
                            # normal procedure (resolving one task should break the
                            # cycle)
                            while !possible_cycles.empty?
                                cycle = possible_cycles.shift
                                next if !can_merge_cycle?(possible_cycles, *cycle)

                                Engine.debug do
                                    "    found cycle merge for #{cycle[0]} => #{cycle[1]}"
                                end
                                merges.link(cycle[0], cycle[1], nil)
                                if possible_cycles.include?([cycle[1], cycle[0]])
                                    merges.link(cycle[1], cycle[0], nil)
                                end
                                break
                            end
                            possible_cycles.clear
                        end
                        if merges.empty?
                            candidates.clear
                            break 
                        end

                        candidates = apply_merge_mappings(merges)
                        merged_tasks.merge(candidates)
                        candidates = merge_tasks_next_step(candidates)
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


