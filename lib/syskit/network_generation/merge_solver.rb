module Syskit
    module NetworkGeneration
        # Implementation of the algorithms needed to reduce a component network
        # to the minimal set of components that are actually needed
        #
        # This is the core of the system deployment algorithm implemented in
        # Engine
        class MergeSolver
            include Utilrb::Timepoints
            extend Logger::Hierarchy
            include Logger::Hierarchy

            # The plan on which this solver applies
            attr_reader :plan

            # A graph that holds all replacements done during resolution
	    attr_reader :task_replacement_graph

            class << self
                # If true, this is a directory path into which SVGs are generated
                # for each steps of the network generation
                attr_accessor :tracing_directory

                # If tracing_directory is set, the options that should be used to
                # generate the graphs
                attr_accessor :tracing_options
            end
            @tracing_options = { :remove_compositions => true }

            def initialize(plan, &block)
                @plan = plan
                @merging_candidates_queries = Hash.new
		@task_replacement_graph = BGL::Graph.new
                @task_replacement_graph.name = "#{self}.task_replacement_graph"
                @resolved_replacements = Hash.new

                if block_given?
                    singleton_class.class_eval do
                        define_method(:merged_tasks, &block)
                    end
                end
            end

            def clear
                @task_replacement_graph.clear
                @resolved_replacements.clear
            end

            # Returns the task that is used in place of the given task
            #
            # @param [Roby::Task] the task for which we want to know the
            #   replacement
            # @return [Roby::Task]
            # @see #register_replacement
            def replacement_for(task)
                if task.plan && task.plan != plan
                    task = plan[task]
                end

                if replacement = @resolved_replacements[task]
                    # Verify that this is still a leaf in the replacement graph
                    if replacement.leaf?(task_replacement_graph)
                        return replacement
                    end
                    @resolved_replacements.delete(task)
                end

                task_replacement_graph.each_dfs(task, BGL::Graph::TREE) do |_, to, _|
                    if to.leaf?(task_replacement_graph)
                        @resolved_replacements[task] = to
                        return to
                    end
                end
                return task
            end

            # Registers a replacement in the plan
            #
            # @param [Roby::Task] old_task the task that is being replaced
            # @param [Roby::Task] new_task the task that replaced old_task
            # @return [void]
            def register_replacement(old_task, new_task)
                task_replacement_graph.link(old_task, new_task, nil)
            end

            # Merge task into target_task, i.e. applies target_task.merge(task)
            # and updates the merge solver's data structures in the process
            def merge(task, target_task)
                if task == target_task
                    raise "trying to merge a task onto itself: #{task}"
                end

                debug { "    #{target_task}.merge(#{task})" }
                if MergeSolver.tracing_directory
                    Engine.autosave_plan_to_dot(plan,
                            MergeSolver.tracing_directory,
                            MergeSolver.tracing_options.merge(:highlights => [task, target_task].to_set, :suffix => "0"))
                end

                if target_task.respond_to?(:merge)
                    target_task.merge(task)
                else
                    plan.replace_task(task, target_task)
                end
                plan.remove_object(task)
                register_replacement(task, target_task)

                if MergeSolver.tracing_directory
                    Engine.autosave_plan_to_dot(plan,
                            MergeSolver.tracing_directory,
                            MergeSolver.tracing_options.merge(:highlights => [task, target_task].to_set, :suffix => "1"))
                end
            end

            # Updates the neighborhood of the given task in the merge graph
            #
            # This is called after having merged another task in target_task, as
            # some merges that were OK before might not be anymore
            def update_merge_graph_neighborhood(merge_graph, target_task)
                # Since we modified +task+, we now have to update the graph.
                # I.e. it is possible that some of +task+'s children cannot be
                # merged into +task+ anymore
                children = target_task.enum_for(:each_child_vertex, merge_graph).to_a
                children.each do |child|
                    if !resolve_single_merge(target_task, child)
                        debug { "      #{target_task}.merge(#{child}) is not a valid merge anymore, updating merge graph" }
                        merge_graph.unlink(target_task, child)
                    end
                end

                parents = target_task.enum_for(:each_parent_vertex, merge_graph).to_a
                parents.each do |parent|
                    if !resolve_single_merge(parent, target_task)
                        debug { "      #{parent}.merge(#{target_task}) is not a valid merge anymore, updating merge graph" }
                        merge_graph.unlink(parent, target_task)
                    end
                end
            end

            # Create a new solver on the given plan and perform
            # {#merge_identical_tasks}
            def self.merge_identical_tasks(plan, &block)
                solver = MergeSolver.new(plan, &block)
                solver.merge_identical_tasks
            end

            # Result table used internally by merge_sort_order
            MERGE_SORT_TRUTH_TABLE = {
                [true, true] => nil,
                [true, false] => -1,
                [false, true] => 1,
                [false, false] => nil }

            # Will return -1 if +t1+ is a better merge target than +t2+
            #
            # When both t1.merge(task) and t2.merge(task) are possible, this is used
            # to know which of the two operations is best
            #
            # @return [-1,nil,1] -1 if t1.merge(task) is better, 1 if t2.merge(task)
            #   is better and nil if there are no criteria to order them
            def merge_sort_order(t1, t2)
                if t1.fullfills?(t2.model)
                    if !t2.fullfills?(t1.model)
                        return 1
                    end
                elsif t2.fullfills?(t1.model)
                    return -1
                end

                MERGE_SORT_TRUTH_TABLE[ [!t1.finished?, !t2.finished?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.running?, !!t2.running?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.execution_agent, !!t2.execution_agent] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!t1.respond_to?(:proxied_data_services), !t2.respond_to?(:proxied_data_services)] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.fully_instanciated?, !!t2.fully_instanciated?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!!t1.transaction_proxy?, !!t2.transaction_proxy?] ]
            end

            # Tests whether task.merge(target_task) is a valid operation
            #
            # @param [Roby::Task] task
            # @param [Roby::Task] target_task
            #
            # @return [false,nil,true] if false, the merge is not possible. If
            #   true, it is possible. If nil, the only thing that makes the
            #   merge impossible are missing inputs, and these tasks might
            #   therefore be merged if there was a dataflow cycle
            def resolve_single_merge(task, target_task)
                # Ask the task about intrinsic merge criteria.
                # Component#can_merge?  should not look at the relation graphs,
                # only at criteria internal to the tasks.
                if !target_task.can_merge?(task)
                    debug { "rejecting #{target_task}.merge(#{task}) as can_merge? returned false" }
                    return false
                end

                # Merges involving a deployed task can only involve a
                # non-deployed task as well
                if task.execution_agent && target_task.execution_agent
                    debug { "rejecting #{target_task}.merge(#{task}) as deployment attribute mismatches" }
                    return false
                end

                # If both tasks are compositions, merge only if +task+
                # has the same child set than +target+
                if task.kind_of?(Composition) && target_task.kind_of?(Composition)
                    task_children   = task.merged_relations(:each_child, true, false).to_value_set
                    target_children = target_task.merged_relations(:each_child, true, false).to_value_set
                    if task_children != target_children || task_children.any? { |t| t.respond_to?(:proxied_data_services) }
                        debug { "rejecting #{target_task}.merge(#{task}) as composition have different children" }
                        return false
                    end

                    task_children.each do |child_task|
                        task_roles = task[child_task, Roby::TaskStructure::Dependency][:roles]
                        target_roles = target_task[child_task, Roby::TaskStructure::Dependency][:roles]
                        if task_roles != target_roles
                            debug { "rejecting #{target_task}.merge(#{task}) as composition have same children but in different roles" }
                            return false
                        end
                    end
                end

                # Finally, check if the inputs match
                mismatching_inputs = resolve_input_matching(task, target_task, Hash.new)
                if !mismatching_inputs
                    debug { "rejecting #{target_task}.merge(#{task}) as their inputs are incompatible" }
                    return false
                elsif mismatching_inputs.empty?
                    debug { "#{target_task}.merge(#{task}) can be done" }
                    return true
                else
                    debug { "#{target_task}.merge(#{task}) might be a cycle" }
                    return nil
                end
            end

            # Returns the set of inputs that differ in two given components,
            # possibly using merge cycle information
            #
            # @param [Hash<Roby::Task,Roby::Task>] mapping from the set of
            #   target tasks into the set of tasks that should be used to
            #   compare the inputs. This is exploited when resolving cycles
            # @return [Array<(String,String,Roby::Task,Roby::Task)>,nil]
            #   If nil, the two tasks have inputs that do not match and could
            #   not match even after a merge cycle resolution pass.
            #   Otherwise, the set of mismatching inputs is returned, in which
            #   each mismatch is a tuple (port_name,source_port,task_source,target_source).
            def resolve_input_matching(task, target_task, mappings)
                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                inputs = Hash.new { |h, k| h[k] = Hash.new }
                task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    inputs[sink_port][[source_task, source_port]] = policy
                end

                mismatched_inputs = []
                target_task.each_concrete_input_connection do |real_target_source_task, target_source_port, sink_port, target_policy|
                    # If +self+ has no connection on +sink_port+, it is valid
                    if !inputs.has_key?(sink_port)
                        next
                    end

                    # We keep is_mapped for later, as we will return nil
                    # (instead of adding to mismatched_inputs) if there is
                    # already a mapping for an input
                    is_mapped = mappings.has_key?(real_target_source_task)
                    target_source_task = mappings[real_target_source_task] || real_target_source_task

                    # If the exact same connection is provided, verify that
                    # the policies match
                    if policy = inputs[sink_port][[target_source_task, target_source_port]]
                        if !policy.empty? && !target_policy.empty? && (Syskit.update_connection_policy(policy, target_policy) != target_policy)
                            debug { "cannot merge #{target_task} into #{self}: incompatible policies on #{sink_port}" }
                            return
                        end
                        next
                    end

                    # Different connections, check whether we could multiplex
                    # them
                    if (port_model = task.model.find_input_port(sink_port)) && port_model.multiplexes?
                        next
                    end

                    # If we are not multiplexing, there can be only one source
                    # for task
                    (source_task, source_port), policy = inputs[sink_port].first
                    if source_port != target_source_port
                        debug { "cannot merge #{target_task} into #{self}: #{sink_port} is connected to a port named #{target_source_port} resp. #{source_port}" }
                        return
                    end
                    if !policy.empty? && !target_policy.empty? && (Syskit.update_connection_policy(policy, target_policy) != target_policy)
                        debug { "cannot merge #{target_task} into #{self}: incompatible policies on #{sink_port}" }
                        return
                    end

                    # If we already have a mapping, it is not possible to
                    # resolve a cycle to make the inputs match. Just say "no"
                    if is_mapped
                        debug { "cannot merge #{target_task} into #{self}: would need to map to multiple tasks while resolving the cycle" }
                        return
                    end

                    mismatched_inputs << [sink_port, source_port, source_task, target_source_task]
                end
                mismatched_inputs
            end

            # Checks if target_task.merge(task) could be done, but taking into
            # account possible dataflow cycles that might exist.
            #
            # It is assumed that resolve_single_merge has already been called to check
            # the sanity of target_task.merge(task), i.e. that the only thing
            # that forbids the merge so far are the inputs
            #
            # @param [Array<(Roby::Task,Roby::Task)>] cycle_candidates 
            #   (task, target_task) pairs that can't be merged only because of
            #   mismatching inputs. This is built by calling
            #   {#resolve_single_merge}
            # @param [Roby::Task] task
            # @param [Roby::Task] target_task
            # @param [{Roby::Task => Roby::Task}] mappings the set of known mappings
            #   from the targets to the tasks
            # @return [{Roby::Task => Roby::Task},nil] the set of merges that should
            #   be applied to resolve the cycle or nil if no cycles could be
            #   resolved.
            def resolve_cycle_candidate(cycle_candidates, task, target_task, mappings = Hash.new)
                debug { "looking to resolve cycle between #{task} and #{target_task}" }
                mappings = mappings.merge(target_task => task)

                mismatched_inputs = resolve_input_matching(task, target_task, mappings)
                if !mismatched_inputs
                    return
                end

                mismatched_inputs.each do |sink_port, source_port, source_task, target_source_task|
                    # Since we recursively call #can_merge_cycle?, we might
                    # already have found a mapping for target_source_task. Take
                    # that into account
                    if known_mapping = mappings[target_source_task]
                        if known_mapping != source_task
                            debug { "#{target_source_task} is already resolved to #{known_mapping}: not matching" }
                            return
                        end
                        debug { "#{target_source_task} is already resolved to #{known_mapping}: matching" }
                        next
                    end

                    if !cycle_candidates.include?([source_task, target_source_task])
                        debug { "not a cycle: #{source_task} and #{target_source_task} are not cycle candidates" }
                        return
                    end


                    new_mappings = 
                        log_nest(2) do
                            resolve_cycle_candidate(
                                cycle_candidates, source_task, target_source_task, mappings)
                        end

                    if new_mappings
                        debug { "resolved cycle: #{source_task} and #{target_source_task} with #{new_mappings}" }
                        mappings.merge!(new_mappings)
                    else
                        debug { "not a cycle: cannot find mapping to merge #{source_task} and #{target_source_task}" }
                        return
                    end
                end
                mappings
            end

            # Find merge candidates and returns them as a graph
            #
            # In the returned graph, an edge 'a' => 'b' means that we can use a
            # to replace b, i.e. a.merge(b) is valid
            #
            # @param [ValueSet<Roby::Task>] task_set the set of tasks for which
            #   we need the merge graph
            # @return [(BGL::Graph,Array<(Roby::Task,Roby::Task)>)] the merge
            #   graph, and a list of (task, target_task) pairs in which the
            #   merge is so far not possible only for input mismatching reasons.
            #   These are therefore candidates for dataflow loop resolution.
            def direct_merge_mappings(task_set)
                cycle_candidates = []

                queries = Hash.new

                # In the loop, we list the possible merge candidates for that
                # task. What we are looking for are tasks that can be used to
                # replace +task+
                merge_graph = BGL::Graph.new
                merge_graph.name = "#{self}.merge_graph"
                for task in task_set
                    # Get the set of candidates. We are checking if the tasks in
                    # this set can be replaced by +task+
                    candidates = queries[task.model]
                    if !candidates
                        candidates = (plan.find_local_tasks(task.model.fullfilled_model).to_value_set & task_set)
                        candidates.delete_if { |t| t.respond_to?(:proxied_data_services) }
                        queries[task.model] = candidates
                    end

                    candidates = candidates.dup
                    candidates.delete(task)
                    if candidates.empty?
                        debug { "no candidates to replace #{task}, using model #{task.model.fullfilled_model.map(&:short_name).join(",")}" }
                        next
                    end

                    debug do
                        candidates.each do |t|
                            debug "RAW #{t}.merge(#{task})"
                        end
                        break
                    end

                    for target_task in candidates
                        if result = resolve_single_merge(task, target_task)
                            debug { "#{target_task}.merge(#{task})" }
                            merge_graph.link(target_task, task, nil)
                        elsif result.nil?
                            debug { "adding #{task} #{target_task} to cycle candidates" }
                            cycle_candidates << [task, target_task]
                        end
                    end
                end
                return merge_graph, cycle_candidates
            end

            # Returns the merge graph for all tasks in {#plan}
            def complete_merge_graph
                all_tasks = plan.find_local_tasks(Syskit::Component).
                    to_value_set
                direct_merge_mappings(all_tasks)
            end

            # Looks for parents in merge_graph for task. If task is both the
            # child and the parent of one of its parents, checks whether we
            # could resolve it per the merge_sort_order order. If we can, update
            # the merge_graph
            #
            # @returns [Array<Roby::Task>] the remaining parents of task in
            #   merge_graph
            def break_parent_child_cycles(merge_graph, task)
                target_tasks = task.enum_for(:each_parent_vertex, merge_graph).to_a
                if target_tasks.empty?
                    return []
                end
                target_tasks.delete_if do |target_task|
                    if task.child_vertex?(target_task, merge_graph)
                        order = merge_sort_order(target_task, task)
                        if order == 1
                            debug do
                                "     picking up #{task}.merge(#{target_task}) for local cycle"
                            end
                            merge_graph.unlink(target_task, task)
                            true

                        elsif order == -1
                            debug do
                                "     picking up #{target_task}.merge(#{task}) for local cycle"
                            end
                            merge_graph.unlink(task, target_task)
                            false
                        end
                    end
                end
                target_tasks
            end

            # When there are multiple merge possibilities for a given task, this
            # method can be called to isolate the "best" ones using
            # {#merge_sort_order}
            def resolve_ambiguities_using_sort_order(merge_graph, task, target_tasks)
                # Check whether some parents are better than other
                # w.r.t. the merge_sort_order relation
                filtered = []
                target_tasks.each do |target_task|
                    do_insert = true
                    filtered.delete_if do |filtered_task|
                        sort = merge_sort_order(filtered_task, target_task)
                        if sort == 1
                            merge_graph.unlink(filtered_task, task)
                            true
                        elsif sort == -1
                            do_insert = false
                        end
                    end

                    if do_insert
                        filtered << target_task
                    else
                        merge_graph.unlink(target_task, task)
                    end
                end
                filtered
            end

            # Preprocess the merge graph created by #direct_merge_mappings,
            # partitioning the registered merges into three categories: 'single
            # parent', 'ambiguous' and 'with cycles'
            #
            # The last returned set, cycle, is the set of tasks for which there
            # exists cycles in the merge graph
            #
            # The first returned set, one_parent, is the set of non-cycle tasks
            # for which there is one and only one target_task such as
            # target_task.merge(task) is possible. For these tasks, the merge
            # resolution is trivial as it consists only of applying the merge.
            #
            # The second set, ambiguous, is the set of non-cycle tasks for which
            # there is more than one parent.
            #
            # @param [BGL::Graph] merge_graph the merge graph created by
            #   {#direct_merge_mappings}
            # @return [(ValueSet<Roby::Task>,ValueSet<Roby::Task>,ValueSet<Roby::Task>)]
            #   the one_parent, ambiguous, with_cycles tuple
            def merge_prepare(merge_graph)
                one_parent, ambiguous, cycles = ValueSet.new, ValueSet.new, ValueSet.new

                parents = Hash.new
                candidates = merge_graph.vertices
                candidates.each do |task|
                    parents[task] = break_parent_child_cycles(merge_graph, task)
                    if parents[task].size > 1
                        parents[task] = resolve_ambiguities_using_sort_order(merge_graph, task, parents[task])
                    end
                end

                parents.each do |task, target_tasks|
                    in_cycle = target_tasks.any? do |target_task|
                        merge_graph.reachable?(task, target_task)
                    end

                    if in_cycle
                        cycles << task
                    elsif target_tasks.size == 1
                        one_parent << task
                    elsif target_tasks.size > 1
                        ambiguous << task
                    end
                end

                return one_parent, ambiguous, cycles
            end

            # Break cycles in the merge graph
            #
            # This is a pretty crude method, that computes some spanning trees
            # issued from each of the elements in +cycles+, and then transforms
            # the merge graph into these trees greedily by starting with the
            # biggest spanning tree.
            def break_simple_merge_cycles(merge_graph, cycles)
                cycles = cycles.map do |task|
                    reachable = ValueSet.new
                    reachable << task
                    to_remove = Array.new
                    debug { "from #{task}" }

                    merge_graph.each_dfs(task, BGL::Graph::ALL) do |edge_from, edge_to, _|
                        if reachable.include?(edge_to)
                            debug { "  remove #{edge_from}.merge(#{edge_to})" }
                            to_remove << [edge_from, edge_to]
                        else
                            debug { "  keep #{edge_from}.merge(#{edge_to})" }
                            reachable << edge_to
                        end
                    end

                    debug do
                        debug "  #{reachable.size} reachable tasks:"
                        reachable.each do |t|
                            debug "    #{t}"
                        end
                        break
                    end

                    [task, reachable, to_remove]
                end
                cycles = cycles.sort_by { |_, reachable, _| -reachable.size }

                ignored = ValueSet.new
                while !cycles.empty?
                    task, reachable, to_remove = cycles.shift
                    debug { "applying tree from #{task}" }
                    to_remove.each do |edge_from, edge_to|
                        debug { "  removing #{edge_from}.merge(#{edge_to})" }
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

            # Apply merges computed by direct_merge_mappings
            #
            # @return [BGL::Graph] the merges that have been performed by
            #   this call. An edge a>b exists in the graph if a has been merged
            #   into b
            def apply_merge_mappings(merge_graph)
                applied_merges = BGL::Graph.new
                while true
                    one_parent, ambiguous, cycles = merge_prepare(merge_graph)
                    if one_parent.empty? && cycles.empty?
                        break
                    elsif one_parent.empty?
                        debug "  -- Breaking simple cycles in the merge graph"
                        break_simple_merge_cycles(merge_graph, cycles)
                    else
                        debug "  -- Applying simple merges"
                        for task in one_parent
                            # there are no guarantees that the tasks in +tasks+ have
                            # only one parent anymore, as we have applied merges
                            # since one_parent was computed
                            target_tasks = task.enum_for(:each_parent_vertex, merge_graph).to_a
                            next if target_tasks.size != 1
                            target_task = target_tasks.first
                            merge(task, target_task)
                            merge_graph.replace_vertex(task, target_task)
                            merge_graph.remove(task)
                            update_merge_graph_neighborhood(merge_graph, target_task)
                            applied_merges.link(task, target_task, nil)
                        end
                    end
                end
                applied_merges
            end

            # Propagation step in the BFS of merge_identical_tasks
            def merge_tasks_next_step(task_set) # :nodoc:
                result = ValueSet.new
                return result if task_set.nil?
                for t in task_set
                    children = t.each_sink(false).to_value_set
                    result.merge(children) if children.size > 1
                    result.merge(t.each_parent_task.to_value_set.delete_if { |parent_task| !parent_task.kind_of?(Composition) })
                end
                result
            end

            def process_possible_cycles(merge_graph, possible_cycles)
                debug "  -- Looking for merges in dataflow cycles"

                # possible_cycles actually stores all the known
                # possible matches since the last outer loop. Some
                # of these pairs might have been merged into other
                # tasks, and some of them might not be current.
                # Filter.
                possible_cycles = possible_cycles.map do |task, target_task|
                    task, target_task = replacement_for(task), replacement_for(target_task)
		    next if merge_graph.linked?(task, target_task)

                    result = resolve_single_merge(task, target_task)
                    if result.nil?
                        [task, target_task]
                    elsif task != target_task && result
                        merge_graph.link(task, target_task, nil)
                        nil
                    end
                end
                possible_cycles = possible_cycles.compact.to_set.to_a

                # Find one cycle to solve. Once we found one, we
                # give the hand to the normal merge processing
                while !possible_cycles.empty?
                    # We remove the cycles as we try to process them
                    # as they are used to filter out impossible
                    # merges (and therefore will speed up the calls
                    # to #resolve_cycle_candidate)
                    cycle = possible_cycles.shift
                    debug { "    checking cycle #{cycle[0]}.merge(#{cycle[1]})" }

                    can_merge = log_nest(4) do
                        resolve_cycle_candidate(possible_cycles, *cycle)
                    end

                    if can_merge
                        debug { "found cycle merge for #{cycle[1]}.merge(#{cycle[1]})" }
                        merge_graph.link(cycle[0], cycle[1], nil)
                        if possible_cycles.include?([cycle[1], cycle[0]])
                            merge_graph.link(cycle[1], cycle[0], nil)
                        end
                        break
                    else
                        debug { "cannot merge cycle #{cycle[0]}.merge(#{cycle[1]})" }
                    end
                end
                return possible_cycles.to_set
            end

            # Merges tasks that are equivalent in the current plan
            #
            # It is a BFS that follows the data flow. I.e., it computes the set
            # of tasks that can be merged and then will look at the children of
            # these tasks and so on and so forth.
            #
            # The step is given by #merge_tasks_next_step
            def merge_identical_tasks
                debug do
                    debug ""
                    debug "----------------------------------------------------"
                    debug "Merging identical tasks"
                    break
                end

                # Get all the tasks we need to consider. That's easy,
                # they all implement the Syskit::Component model
                all_tasks = plan.find_local_tasks(Syskit::Component).
                    to_value_set

                debug do
                    debug "-- Tasks in plan"
                    all_tasks.each do |t|
                        debug "    #{t}"
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

                possible_cycles = Set.new
                merged_tasks = ValueSet.new
                pass_idx = 0
                while !candidates.empty?
                    pass_idx += 1
                    add_timepoint 'merge', 'pass', pass_idx, "start"
                    merged_tasks.clear
                    possible_cycles.clear

                    while !candidates.empty? || !possible_cycles.empty?
                        candidates.delete_if do |task|
                            # We never replace a transaction proxy. We only use them to
                            # replace new tasks in the transaction
                            if task.transaction_proxy?
                                debug { "cannot replace #{task}: is a transaction proxy" }
                                true
                            end
                            # Don't do service allocation at this stage. It should be
                            # done at the specification stage already
                            if task.respond_to?(:proxied_data_services)
                                debug { "cannot replace #{task}: is a data service proxy" }
                                true
                            end
                        end

                        debug "  -- Raw merge candidates"
                        merge_graph, cycle_candidates = log_nest(4) do
                            direct_merge_mappings(candidates)
                        end
                        candidates.clear
                        possible_cycles |= cycle_candidates.to_set
                        debug "    #{merge_graph.size} vertices in merge graph"
                        debug "    #{cycle_candidates.size} new possible cycles"
                        debug "    #{possible_cycles.size} known possible cycles"

                        if merge_graph.empty?
                            # No merge found so far, try resolving some cycles
                            possible_cycles = process_possible_cycles(merge_graph, possible_cycles)
                        end

                        applied_merges = apply_merge_mappings(merge_graph)
                        next_step_seeds = applied_merges.vertices.
                            find_all { |task| task.leaf?(applied_merges) }.
                            to_value_set                         
                        candidates = merge_tasks_next_step(next_step_seeds)
                        merged_tasks.merge(candidates)
                        debug do
                            debug "  -- Merged tasks during this pass"
                            next_step_seeds.each { |t| debug "    #{t}" }
                            debug "  -- Candidates for next pass"
                            candidates.each { |t| debug "    #{t}" }
                            break
                        end

                        # This is just to make the job of the Ruby GC easier
                        merge_graph.clear
                        applied_merges.clear
                        cycle_candidates.clear
                    end

                    debug "  -- Parents"
                    for t in merged_tasks
                        parents = t.each_parent_task.to_value_set
                        candidates.merge(parents) if parents.size > 1
                    end
                    add_timepoint 'merge', 'pass', pass_idx, "done"
                end

                debug do
                    debug "done merging identical tasks"
                    debug "----------------------------------------------------"
                    debug ""
                    break
                end
            end

            def display_merge_graph(title, merge_graph)
                debug "  -- #{title}"
                debug do
                    merge_graph.each_vertex do |vertex|
                        vertex.each_child_vertex(merge_graph) do |child|
                            debug "    #{vertex}.merge(#{child})"
                        end
                    end
                    break
                end
            end
        end
    end
end


