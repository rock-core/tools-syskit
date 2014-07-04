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

            # Create a new solver on the given plan and perform
            # {#merge_identical_tasks}
            def self.merge_identical_tasks(plan, &block)
                solver = MergeSolver.new(plan, &block)
                solver.merge_identical_tasks
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
                mismatching_inputs = resolve_input_matching(task, target_task)
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
            def resolve_input_matching(task, target_task)
                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                inputs = Hash.new { |h, k| h[k] = Hash.new }
                task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    inputs[sink_port][[source_task, source_port]] = policy
                end

                mismatched_inputs = []
                target_task.each_concrete_input_connection do |target_source_task, target_source_port, sink_port, target_policy|
                    # If +self+ has no connection on +sink_port+, it is valid
                    if !inputs.has_key?(sink_port)
                        next
                    end

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
                        debug { "cannot merge #{target_task} into #{task}: #{sink_port} is connected to a port named #{target_source_port} resp. #{source_port}" }
                        return
                    end
                    if !policy.empty? && !target_policy.empty? && (Syskit.update_connection_policy(policy, target_policy) != target_policy)
                        debug { "cannot merge #{target_task} into #{task}: incompatible policies on #{sink_port}" }
                        return
                    end

                    mismatched_inputs << [sink_port, source_port, source_task, target_source_task]
                end
                mismatched_inputs
            end

            def update_cycle_mapping(mappings, task, target_task)
                task_m   = mappings[task] || [task].to_set
                target_m = mappings[target_task] || [target_task].to_set
                m = task_m | target_m
                m.each do |t|
                    mappings[t] = m
                end
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
                update_cycle_mapping(mappings, task, target_task)

                mismatched_inputs = resolve_input_matching(task, target_task)
                if !mismatched_inputs
                    return
                end

                mismatched_inputs.each do |sink_port, source_port, source_task, target_source_task|
                    # Since we recursively call #can_merge_cycle?, we might
                    # already have found a mapping for target_source_task. Take
                    # that into account
                    if known_mappings = mappings[target_source_task]
                        if known_mappings.include?(target_source_task)
                            debug { "#{target_source_task} and #{source_task} are already paired in the cycle merge: matching" }
                            next
                        end
                    end

                    if !cycle_candidates.include?([source_task, target_source_task])
                        debug { "not a cycle: #{source_task} and #{target_source_task} are not cycle candidates" }
                        return
                    end


                    resolved_cycle = log_nest(2) do
                        resolve_cycle_candidate(
                            cycle_candidates, source_task, target_source_task, mappings)
                    end

                    if resolved_cycle
                        debug { "resolved cycle: #{source_task} and #{target_source_task}" }
                    else
                        debug { "not a cycle: cannot find mapping to merge #{source_task} and #{target_source_task}" }
                        return
                    end
                end
                true
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
                applied_merges = BGL::Graph.new
                cycle_candidates = []
                task_set  = task_set.to_set
                processing_queue = task_set.sort_by { |t| Flows::DataFlow.in_degree(t) }

                while !processing_queue.empty?
                    task = processing_queue.shift
                    # 'task' could have been merged already, ignore it
                    next if !plan.include?(task)

                    # Get the set of candidates. We are checking if the tasks in
                    # this set can be replaced by +task+
                    candidates = plan.find_local_tasks(task.model.fullfilled_model)
                    debug { "#{candidates.to_a.size} candidates for #{task}" }
                    candidates = candidates.sort_by { |t| Flows::DataFlow.in_degree(t) }
                        
                    candidates.each do |target_task|
                        next if task == target_task ||
                            target_task.respond_to?(:proxied_data_services) ||
                            !task_set.include?(target_task)

                        debug { "RAW #{target_task}.merge(#{task})" }
                        if result = resolve_single_merge(task, target_task)
                            debug { "#{target_task}.merge(#{task})" }
                            applied_merges.link(task, target_task, nil)
                            merge(task, target_task)
                            break
                        elsif result.nil?
                            debug { "adding #{task} #{target_task} to cycle candidates" }
                            cycle_candidates << [task, target_task]
                        end
                    end
                end
                return applied_merges, cycle_candidates
            end

            # Returns the merge graph for all tasks in {#plan}
            def complete_merge_graph
                all_tasks = plan.find_local_tasks(Syskit::Component).
                    to_value_set
                direct_merge_mappings(all_tasks)
            end

            # Propagation step in the BFS of merge_identical_tasks
            def merge_tasks_next_step(task_set) # :nodoc:
                result = ValueSet.new
                return result if task_set.nil?
                for t in task_set
                    sinks = t.each_concrete_output_connection.map do |_, _, sink_task, _|
                        sink_task
                    end
                    result.merge(sinks.to_value_set) if sinks.size > 1
                end
                result
            end

            # Processes cycles
            #
            # It stops as soon as one cycle got resolved. The corresponding cycle seeds
            # get added to the merge graph.
            #
            # @param [Set<(Component,Component)>] possible_cycles possible cycle seeds
            # @return [Set<(Component,Component)>] cycle seeds that have not been processed
            def process_possible_cycles(possible_cycles)
                debug "  -- Looking for merges in dataflow cycles"

                # possible_cycles actually stores all the known
                # possible matches since the last outer loop. Some
                # of these pairs might have been merged into other
                # tasks, and some of them might not be current.
                # Filter.
                possible_cycles = possible_cycles.map do |task, target_task|
                    task, target_task = replacement_for(task), replacement_for(target_task)
                    next if task == target_task

                    result = resolve_single_merge(task, target_task)
                    if result.nil?
                        [task, target_task]
                    else
                        raise InternalError, "#{target_task}.merge(#{task}) can be done as-is, it should not be possible at this stage"
                    end
                end
                possible_cycles = possible_cycles.compact
                applied_merges = BGL::Graph.new

                # Find one cycle to solve. Once we found one, we
                # give the hand to the normal merge processing
                while !possible_cycles.empty?
                    # We remove the cycles as we try to process them
                    # as they are used to filter out impossible
                    # merges (and therefore will speed up the calls
                    # to #resolve_cycle_candidate)
                    target_task, task = possible_cycles.shift
                    debug { "    checking cycle #{target_task}.merge(#{task})" }

                    can_merge = log_nest(4) do
                        resolve_cycle_candidate(possible_cycles, target_task, task)
                    end

                    if can_merge
                        debug { "found cycle merge for #{target_task}.merge(#{task})" }
                        merge(task, target_task)
                        applied_merges.link(task, target_task, nil)
                        break
                    else
                        debug { "cannot merge cycle candidate #{target_task}.merge(#{task})" }
                    end
                end
                return applied_merges, possible_cycles.to_set
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
                all_tasks = plan.find_local_tasks(Syskit::TaskContext).
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
                    add_timepoint 'merge', 'pass', "start", pass_idx
                    merged_tasks.clear

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

                        debug do
                            debug "-- #{candidates.size} merge candidates"
                            candidates.each do |t|
                                debug "    #{t}"
                            end
                            break
                        end
                        debug "  -- Raw merge candidates"
                        applied_merges, cycle_candidates = log_nest(4) do
                            direct_merge_mappings(candidates)
                        end
                        candidates.clear
                        possible_cycles |= cycle_candidates.to_set
                        debug "    the applied merges graph has #{applied_merges.size} vertices"
                        debug "    #{cycle_candidates.size} new possible cycles"
                        debug "    #{possible_cycles.size} known possible cycles"

                        if applied_merges.empty?
                            # No merge found so far, try resolving some cycles
                            applied_merges, possible_cycles =
                                process_possible_cycles(possible_cycles)
                            debug "    the applied merges graph has #{applied_merges.size} vertices"
                        end

                        next_step_seeds = applied_merges.vertices.
                            find_all { |task| task.leaf?(applied_merges) }.
                            to_value_set                         
                        candidates = merge_tasks_next_step(next_step_seeds)
                        merged_tasks.merge(next_step_seeds)
                        debug do
                            debug "  #{merged_tasks.size} merged tasks so far in this pass"
                            debug "  -- Merged tasks during this pass"
                            next_step_seeds.each { |t| debug "    #{t}" }
                            debug "  -- Candidates for next pass"
                            candidates.each { |t| debug "    #{t}" }
                            break
                        end

                        # This is just to make the job of the Ruby GC easier
                        applied_merges.clear
                        cycle_candidates.clear
                    end

                    debug "  -- Parents"
                    debug "  #{merged_tasks.size} tasks have been merged"
                    for t in merged_tasks
                        parents = t.each_parent_task.to_value_set
                        debug { "  #{t}: #{parents.size} parents" }
                        if parents.size > 1
                            candidates.merge(parents) 
                        end
                    end
                    add_timepoint 'merge', 'pass', "done", pass_idx
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


