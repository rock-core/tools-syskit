module Syskit
    module NetworkGeneration
        # Implementation of the algorithms needed to reduce a component network
        # to the minimal set of components that are actually needed
        #
        # This is the core of the system deployment algorithm implemented in
        # Engine
        class MergeSolver
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The plan on which this solver applies
            attr_reader :plan

            # The dataflow graph for {#plan}
            attr_reader :dataflow_graph

            # The dataflow graph for {#plan}
            attr_reader :dependency_graph

            # A graph that holds all replacements done during resolution
	    attr_reader :task_replacement_graph

            # The list of merges that are known to be invalid, as (merged_task,
            # task)
            #
            # @return [Set<(Syskit::Component,Syskit::Component)>]
            attr_reader :invalid_merges

            class << self
                # If true, this is a directory path into which SVGs are generated
                # for each steps of the network generation
                attr_accessor :tracing_directory

                # If tracing_directory is set, the options that should be used to
                # generate the graphs
                attr_accessor :tracing_options
            end
            @tracing_options = { :remove_compositions => true }

            # The {Roby::DRoby::EventLogger} object on which we log performance
            # information
            attr_reader :event_logger

            def initialize(plan, event_logger: plan.event_logger)
                @plan = plan
                @event_logger = event_logger
                @dataflow_graph = plan.task_relation_graph_for(Flows::DataFlow)
                @dependency_graph = plan.task_relation_graph_for(Roby::TaskStructure::Dependency)
                @merging_candidates_queries = Hash.new
		@task_replacement_graph = Roby::Relations::BidirectionalDirectedAdjacencyGraph.new
                @resolved_replacements = Hash.new
                @invalid_merges = Set.new
            end

            def clear
                @task_replacement_graph.clear
                @resolved_replacements.clear
                @invalid_merges.clear
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
                    if task_replacement_graph.leaf?(replacement)
                        return replacement
                    end
                    @resolved_replacements.delete(task)
                end

                task_replacement_graph.depth_first_visit(task) do |to|
                    if task_replacement_graph.leaf?(to)
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
                task_replacement_graph.add_edge(old_task, new_task, nil)
            end

            # Apply a set of merges computed by {#resolve_merge}
            def apply_merge_group(merged_task_to_task)
                debug do
                    merged_task_to_task.each do |merged_task, task|
                        debug "merging"
                        log_nest(2) do
                            log_pp :debug, merged_task
                        end
                        debug "into"
                        log_nest(2) do
                            log_pp :debug, task
                        end
                    end
                    break
                end

                merged_task_to_task.each do |merged_task, task|
                    if merged_task == task
                        raise "trying to merge a task onto itself: #{merged_task}"
                    end
                    if task.respond_to?(:merge)
                        task.merge(merged_task)
                    end
                end

                merged_event_to_event = Hash.new
                event_resolver = ->(e) { merged_task_to_task[e.task].event(e.symbol) }
                merged_task_to_task.each do |merged_task, task|
                    merged_task.each_event do |ev|
                        merged_event_to_event[ev] = [nil, event_resolver]
                    end
                end
                plan.replace_subplan(merged_task_to_task, merged_event_to_event)

                if concrete_graph = dataflow_graph.concrete_connection_graph
                    merged_task_to_task.each do |old, new|
                        concrete_graph.replace_vertex(old, new)
                    end
                end

                merged_task_to_task.each do |merged_task, task|
                    if !merged_task.transaction_proxy?
                        plan.remove_task(merged_task)
                    end
                    register_replacement(merged_task, task)
                end
            end

            # Create a new solver on the given plan and perform
            # {#merge_identical_tasks}
            def self.merge_identical_tasks(plan)
                solver = MergeSolver.new(plan)
                solver.merge_identical_tasks
            end

            # Tests whether task.merge(target_task) is a valid operation
            #
            # @param [Syskit::TaskContext] task
            # @param [Syskit::TaskContext] target_task
            #
            # @return [false,true] if false, the merge is not possible. If
            #   true, it is possible. If nil, the only thing that makes the
            #   merge impossible are missing inputs, and these tasks might
            #   therefore be merged if there was a dataflow cycle
            def may_merge_task_contexts?(merged_task, task)
                can_merge = log_nest(2) do
                    task.can_merge?(merged_task)
                end

                # Ask the task about intrinsic merge criteria.
                # Component#can_merge?  should not look at the relation graphs,
                # only at criteria internal to the tasks.
                if !can_merge
                    info "rejected: can_merge? returned false"
                    return false
                end

                # A transaction proxy can only be the merged-into task
                if merged_task.transaction_proxy?
                    info "rejected: merged task is a transaction proxy"
                    return false
                end

                # Merges involving a deployed task can only involve a
                # non-deployed task as well
                if task.execution_agent && merged_task.execution_agent
                    info "rejected: deployment attribute mismatches"
                    return false
                end

                true
            end

            def each_component_merge_candidate(task)
                # Get the set of candidates. We are checking if the tasks in
                # this set can be replaced by +task+
                candidates = plan.find_local_tasks(task.model.concrete_model).
                    to_a
                debug do
                    debug "#{candidates.to_a.size - 1} candidates for #{task}, matching model"
                    debug "  #{task.model.concrete_model}"
                    break
                end

                candidates.each do |merged_task|
                    next if task == merged_task 

                    debug { "  #{merged_task}" }
                    if merged_task.respond_to?(:proxied_data_services)
                        debug "    data service proxy"
                        next
                    elsif !merged_task.plan 
                        debug "    removed from plan"
                        next
                    elsif invalid_merges.include?([merged_task, task])
                        debug "    already evaluated as an invalid merge"
                        next
                    end
                    yield(merged_task)
                end
            end

            def each_task_context_merge_candidate(task)
                each_component_merge_candidate(task) do |merged_task|
                    if may_merge_task_contexts?(merged_task, task)
                        debug "  may merge"
                        yield(merged_task)
                    else
                        debug "  invalid merge: may_merge_task_contexts? returned false"
                        invalid_merges << [merged_task, task]
                    end
                end
            end

            # Merge the task contexts
            def merge_task_contexts
                debug "merging task contexts"

                queue = plan.find_local_tasks(Syskit::TaskContext).sort_by do |t|
                    dataflow_graph.in_degree(t)
                end.reverse

                invalid_merges.clear
                while !queue.empty?
                    task = queue.shift
                    # 'task' could have been merged already, ignore it
                    next if !task.plan

                    each_task_context_merge_candidate(task) do |merged_task|
                        # Try to resolve the merge
                        can_merge, mappings =
                            resolve_merge(merged_task, task, merged_task => task)

                        if can_merge
                            apply_merge_group(mappings)
                        else
                            invalid_merges.merge(mappings.to_a)
                        end
                    end
                end
            end

            def enumerate_composition_exports(task)
                task_exports = Set.new
                task.each_input_connection do |source_task, source_port, sink_port, _|
                    if task.find_output_port(sink_port)
                        task_exports << [source_task, source_port, sink_port]
                    end
                end
                task.each_output_connection do |source_port, sink_task, sink_port, _|
                    if task.find_input_port(source_port)
                        task_exports << [source_port, sink_task, sink_port]
                    end
                end
                task_exports
            end

            def composition_children_by_role(task)
                result = Hash.new
                task_children_names = task.model.children_names.to_set
                task_children   = task.each_out_neighbour_merged(Roby::TaskStructure::Dependency, intrusive: true).map do |child_task|
                    dependency_graph.edge_info(task, child_task)[:roles].each do |r|
                        if task_children_names.include?(r)
                            result[r] = child_task
                        end
                    end
                end
                result
            end

            def may_merge_compositions?(merged_task, task)
                if !may_merge_task_contexts?(merged_task, task)
                    return false
                end

                merged_task_children = composition_children_by_role(merged_task)
                task_children        = composition_children_by_role(task)
                merged_children = merged_task_children.merge(task_children) do |role, merged_task_child, task_child|
                    if merged_task_child == task_child
                        merged_task_child
                    else
                        info "rejected: compositions with different children or children in different roles"
                        debug do
                            debug "  in role #{role},"
                            log_nest(2) do
                                log_pp(:debug, merged_task_child)
                            end
                            log_nest(2) do
                                log_pp(:debug, task_child)
                            end
                        end
                        return false
                    end
                end

                if merged_children.each_value.any? { |t| t.respond_to?(:proxied_data_services) }
                    info "rejected: compositions still have unresolved children"
                    return false
                end

                # Now verify that the exported ports are the same
                task_exports = enumerate_composition_exports(task)
                merged_task_exports = enumerate_composition_exports(merged_task)
                if merged_task_exports != task_exports
                    info "rejected: compositions with different exports"
                    return false
                end

                true
            end

            def each_composition_merge_candidate(task)
                each_component_merge_candidate(task) do |merged_task|
                    if may_merge_compositions?(merged_task, task)
                        yield(merged_task)
                    else
                        invalid_merges << [merged_task, task]
                    end
                end
            end

            def merge_compositions
                debug "merging compositions"

                queue   = Array.new
                topsort = Array.new
                degrees = Hash.new
                dependency_graph.each_vertex do |task|
                    d = dependency_graph.out_degree(task)
                    queue << task if d == 0
                    degrees[task] = d
                end

                while !queue.empty?
                    task = queue.shift
                    if task.kind_of?(Syskit::Composition)
                        topsort << task
                    end
                    dependency_graph.each_in_neighbour(task) do |parent|
                        d = (degrees[parent] -= 1)
                        queue << parent if d == 0
                    end
                end

                topsort.each do |composition|
                    next if !composition.plan
                    each_composition_merge_candidate(composition) do |merged_composition|
                        apply_merge_group(merged_composition => composition)
                    end
                end
            end

            def resolve_merge(merged_task, task, mappings)
                mismatched_inputs = log_nest(2) { resolve_input_matching(merged_task, task) }
                if !mismatched_inputs
                    # Incompatible inputs
                    return false, mappings
                end

                mismatched_inputs.each do |sink_port, merged_source_task, source_task|
                    info do
                        info "  looking to pair the inputs of port #{sink_port} of"
                        info "    #{merged_source_task}"
                        info "    -- and --"
                        info "    #{source_task}"
                        break
                    end

                    if mappings[merged_source_task] == source_task
                        info "  are already paired in the merge resolution: matching"
                        next
                    elsif !may_merge_task_contexts?(merged_source_task, source_task)
                        info "  rejected: may not be merged"
                        return false, mappings
                    end

                    can_merge, mappings = log_nest(2) do
                        resolve_merge(merged_source_task, source_task,
                                      mappings.merge(merged_source_task => source_task))
                    end

                    if can_merge
                        info "  resolved"
                    else
                        info "  rejected: cannot find mapping to merge both tasks"
                        return false, mappings
                    end
                end

                return true, mappings
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
            def resolve_input_matching(merged_task, task)
                m_inputs = Hash.new { |h, k| h[k] = Hash.new }
                merged_task.each_concrete_input_connection do |m_source_task, m_source_port, sink_port, m_policy|
                    m_inputs[sink_port][[m_source_task, m_source_port]] = m_policy
                end

                mismatched_inputs = []
                task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    # If +self+ has no connection on +sink_port+, it is valid
                    if !m_inputs.has_key?(sink_port)
                        next
                    end

                    if m_policy = m_inputs[sink_port][[source_task, source_port]]
                        if !m_policy.empty? && !policy.empty? && (Syskit.update_connection_policy(m_policy, policy) != policy)
                            debug { "rejected: incompatible policies on #{sink_port}" }
                            return
                        end
                        next
                    end

                    # Different connections, check whether we could multiplex
                    # them
                    if (port_model = merged_task.model.find_input_port(sink_port)) && port_model.multiplexes?
                        next
                    end

                    # If we are not multiplexing, there can be only one source
                    # for merged_task
                    (m_source_task, m_source_port), m_policy = m_inputs[sink_port].first
                    if m_source_port != source_port
                        debug { "rejected: sink #{sink_port} is connected to a port named #{m_source_port} resp. #{source_port}" }
                        return
                    end
                    if !m_policy.empty? && !policy.empty? && (Syskit.update_connection_policy(m_policy, policy) != policy)
                        debug { "rejected: incompatible policies on #{sink_port}" }
                        return
                    end

                    mismatched_inputs << [sink_port, m_source_task, source_task]
                end
                mismatched_inputs
            end

            # Returns the merge graph for all tasks in {#plan}
            def complete_merge_graph
                all_tasks = plan.find_local_tasks(Syskit::Component).
                    to_set
                direct_merge_mappings(all_tasks)
            end

            def merge_identical_tasks
                log_timepoint_group_start 'syskit-merge-solver'
                dataflow_graph.enable_concrete_connection_graph
                log_timepoint_group 'merge_task_contexts' do
                    merge_task_contexts
                end
                log_timepoint_group 'merge_compositions' do
                    merge_compositions
                end
            ensure
                dataflow_graph.disable_concrete_connection_graph
                log_timepoint_group_end 'syskit-merge-solver'
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


