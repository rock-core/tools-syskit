# frozen_string_literal: true

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

            # The dependency graph for {#plan}
            attr_reader :dependency_graph

            # A graph that holds all replacements done during resolution
            attr_reader :task_replacement_graph

            # The list of merges that are known to be invalid, as (merged_task,
            # task)
            #
            # @return [Set<(Syskit::Component,Syskit::Component)>]
            attr_reader :invalid_merges

            # The {Roby::DRoby::EventLogger} object on which we log performance
            # information
            attr_reader :event_logger

            def initialize(plan, event_logger: plan.event_logger)
                @plan = plan
                @event_logger = event_logger
                @dataflow_graph = plan.task_relation_graph_for(Flows::DataFlow)
                @dependency_graph = plan.task_relation_graph_for(Roby::TaskStructure::Dependency)
                @merging_candidates_queries = {}
                @task_replacement_graph = Roby::Relations::BidirectionalDirectedAdjacencyGraph.new
                @resolved_replacements = {}
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
                task
            end

            # Registers a replacement in the plan
            #
            # @param [Roby::Task] old_task the task that is being replaced
            # @param [Roby::Task] new_task the task that replaced old_task
            # @return [void]
            def register_replacement(old_task, new_task)
                if concrete_graph = dataflow_graph.concrete_connection_graph
                    concrete_graph.replace_vertex(old_task, new_task)
                end

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

                if self.class.trace?
                    remove_compositions = true
                    if merged_task_to_task.each_key.any? { |t| t.kind_of?(Syskit::Composition) }
                        remove_compositions = false
                    end
                    self.class.trace_export(plan, phase: 1, highlights: (merged_task_to_task.keys + merged_task_to_task.values), remove_compositions: remove_compositions)
                end

                merged_task_to_task.each do |merged_task, task|
                    if merged_task == task
                        raise "trying to merge a task onto itself: #{merged_task}"
                    end

                    if task.respond_to?(:merge)
                        task.merge(merged_task)
                    end
                end

                merged_event_to_event = {}
                event_resolver = ->(e) { merged_task_to_task[e.task].event(e.symbol) }
                merged_task_to_task.each_key do |merged_task|
                    merged_task.each_event do |ev|
                        merged_event_to_event[ev] = [nil, event_resolver]
                    end
                end

                task_replacements = merged_task_to_task.transform_values do |task|
                    [task]
                end
                plan.replace_subplan(task_replacements, merged_event_to_event)

                merged_task_to_task.each do |merged_task, task|
                    unless merged_task.transaction_proxy?
                        plan.remove_task(merged_task)
                    end
                    register_replacement(merged_task, task)
                end

                if self.class.trace?
                    self.class.trace_export(plan, phase: 2, highlights: merged_task_to_task.values, remove_compositions: remove_compositions)
                end
            end

            def self.enable_tracing
                @@trace_enabled = true
            end

            def self.disable_tracing
                @@trace_enabled = false
            end

            def self.trace?
                @@trace_enabled
            end

            def self.trace_file_pattern
                @@trace_file_pattern
            end

            def self.trace_file_pattern=(pattern)
                @@trace_file_pattern = pattern
            end

            @@trace_file_pattern = "syskit-trace-%04i.%i"
            @@trace_enabled = false
            @@trace_count = 0
            @@trace_last_phase = 1

            def self.trace_next_file(phase)
                if @@trace_last_phase >= phase
                    @@trace_count += 1
                end
                @@trace_last_phase = phase
                format(trace_file_pattern, @@trace_count, phase)
            end

            def self.trace_export(plan, phase: 1, highlights: [], **dataflow_options)
                basename = trace_next_file(phase)
                dataflow = basename + ".dataflow.svg"
                hierarchy = basename + ".hierarchy.svg"
                Syskit::Graphviz.new(plan).to_file("dataflow", "svg", dataflow, highlights: highlights, **dataflow_options)
                Syskit::Graphviz.new(plan).to_file("hierarchy", "svg", hierarchy, highlights: highlights)
                ::Robot.info "#{self} exported trace plan to #{dataflow} and #{hierarchy}"
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
                unless can_merge
                    info "rejected: can_merge? returned false"
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
                candidates = plan.find_local_tasks(task.model.concrete_model)
                                 .to_a
                debug do
                    debug "#{candidates.to_a.size - 1} candidates for #{task}, matching model"
                    debug "  #{task.model.concrete_model}"
                    break
                end

                candidates.each do |merged_task|
                    next if task == merged_task

                    debug { "  #{merged_task}" }
                    if merged_task.placeholder?
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
                until queue.empty?
                    task = queue.shift
                    # 'task' could have been merged already, ignore it
                    next unless task.plan

                    each_task_context_merge_candidate(task) do |merged_task|
                        # Try to resolve the merge
                        result = resolve_merge(merged_task, task, merged_task => task)
                        if result.can_merge?
                            apply_merge_group(result.mappings)
                        else
                            invalid_merges << [merged_task, task]
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
                result = {}
                task_children_names = task.model.children_names.to_set
                task.each_out_neighbour_merged(
                    Roby::TaskStructure::Dependency, intrusive: true
                )
                    .map do |child_task|
                        dependency_graph.edge_info(task, child_task)[:roles].each do |r|
                            if task_children_names.include?(r)
                                result[r] = child_task
                            end
                        end
                    end
                result
            end

            def may_merge_compositions?(merged_task, task)
                unless may_merge_task_contexts?(merged_task, task)
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

                if merged_children.each_value.any?(&:placeholder?)
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

                queue   = []
                topsort = []
                degrees = {}
                plan.each_task do |task|
                    d = dependency_graph.out_degree(task)
                    queue << task if d == 0
                    degrees[task] = d
                end

                until queue.empty?
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
                    next unless composition.plan

                    each_composition_merge_candidate(composition) do |merged_composition|
                        apply_merge_group(merged_composition => composition)
                    end
                end
            end

            # Representation of the result of {#resolve_merge}
            MergeResolution = Struct.new(
                :mappings, :merged_task, :task, :merged_failure_chain, :failure_chain
            ) do
                # Whether the merge resolution was successful
                def can_merge?
                    !failure_chain
                end

                def pretty_print_failure(pp)
                    pp.text "Chain 1 cannot be merged in chain 2:"
                    [[merged_task, merged_failure_chain], [task, failure_chain]]
                        .each_with_index do |(task, chain), i|
                            pp.breakable
                            pp.text "Chain #{i + 1}:"
                            pp.nest(2) do
                                pp.breakable
                                task.pretty_print(pp)
                                chain.each do |connection|
                                    pp.breakable
                                    pp.text "sink #{connection.sink_port}_port connected "
                                    pp.text "via policy #{connection.policy} to source "
                                    pp.text "#{connection.source_port}_port of"
                                    pp.breakable
                                    connection.source_task.pretty_print(pp)
                                end
                            end
                        end
                end
            end

            Connection = Struct.new(
                :source_task, :source_port, :policy, :sink_port, :sink_task
            )

            # Resolve merge between N tasks with the given tasks as seeds
            #
            # The method will cycle through the task's mismatching inputs (if
            # there are any) and recursively resolve them, until it determines
            # if the whole group can or cannot be merged
            #
            # @param [Syskit::TaskContext] merged_task task that is being considered
            #   to be merged into 'task'
            # @param [Syskit::TaskContext] task the task into which merged_task will
            #   be merged. I.e. the operation is `task.merge(merged_task)``
            # @param [{Syskit::TaskContext=>Syskit::TaskContext}] mappings hash
            #   of "known good" merges that do not consider the dataflow (i.e. only
            #   considering intrinsic properties of the tasks themselves)
            #
            # @return [MergeResolution]
            def resolve_merge(merged_task, task, mappings)
                unless may_merge_task_contexts?(merged_task, task)
                    return MergeResolution.new(mappings, merged_task, task, [], [])
                end

                mismatched_inputs, failed_connections = log_nest(2) do
                    resolve_input_matching(merged_task, task)
                end

                unless mismatched_inputs
                    return MergeResolution.new(
                        mappings, merged_task, task,
                        [failed_connections[0]], [failed_connections[1]]
                    )
                end

                mappings = mappings.merge({ merged_task => task })
                mismatched_inputs.each do |connection, m_connection|
                    next unless (result = process_port_mismatch(connection, m_connection, mappings))
                    return result unless result.can_merge?

                    mappings = result.mappings
                end

                MergeResolution.new(mappings, merged_task, task)
            end

            # @api private
            #
            # Process the mismatch between two connections as returned by
            # {#resolve_input_matching}
            #
            # @param [Connection] connection the mismatching connection on the
            #   merge-target side
            # @param [Connection] connection the mismatching connection on the
            #   to-be-merged side
            # @return [MergeResolution] merge result
            def process_port_mismatch(connection, m_connection, mappings)
                sink_port = connection.sink_port
                merged_source_task = m_connection.source_task
                source_task = connection.source_task

                info do
                    info "  looking to pair the inputs of port #{sink_port} of"
                    info "    #{merged_source_task}"
                    info "    -- and --"
                    info "    #{source_task}"
                    break
                end

                if mappings[merged_source_task] == source_task
                    info "  are already paired in the merge resolution: matching"
                    return
                end

                resolution = log_nest(2) do
                    resolve_merge(merged_source_task, source_task, mappings)
                end

                if resolution.can_merge?
                    info "  resolved"
                    resolution
                else
                    info "  rejected: cannot find mapping to merge both tasks"
                    MergeResolution.new(
                        resolution.mappings, m_connection.sink_task, connection.sink_task,
                        [connection] + resolution.failure_chain,
                        [m_connection] + resolution.merged_failure_chain
                    )
                end
            end

            def compatible_policies?(policy, other_policy)
                policy.empty? || other_policy.empty? ||
                    (Syskit.update_connection_policy(other_policy, policy) == policy)
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
                return [], nil if merged_task.equal?(task)

                m_inputs = Hash.new { |h, k| h[k] = {} }
                merged_task.each_concrete_input_connection do |m_source_task, m_source_port, sink_port, m_policy|
                    m_inputs[sink_port][[m_source_task, m_source_port]] =
                        Connection.new(m_source_task, m_source_port, m_policy,
                                       sink_port, merged_task)
                end

                mismatched_inputs =
                    task.each_concrete_input_connection
                        .filter_map do |source_task, source_port, sink_port, policy|
                        # If merged_task has no connection on sink_port, the merge
                        # is always valid
                        next unless m_inputs.key?(sink_port)

                        connection = Connection.new(
                            source_task, source_port, policy, sink_port, task
                        )

                        port_model = merged_task.model.find_input_port(sink_port)
                        resolved, m_failed_connection =
                            if port_model&.multiplexes?
                                resolve_multiplexing_input(
                                    connection, m_inputs[sink_port]
                                )
                            else
                                resolve_input(connection, m_inputs[sink_port])
                            end

                        unless resolved
                            return nil, [m_failed_connection, connection]
                        end

                        resolved unless resolved.empty?
                    end

                [mismatched_inputs, nil]
            end

            def resolve_multiplexing_input(connection, m_inputs)
                m_connection = m_inputs[[connection.source_task, connection.source_port]]
                return [], nil unless m_connection

                # Already connected to the same task and port, we
                # just need to check whether the connections are
                # compatible
                return [], nil if compatible_policies?(connection.policy, m_connection.policy)

                debug do
                    "rejected: incompatible policies on #{sink_port}"
                end
                [nil, m_connection]
            end

            def resolve_input(connection, m_inputs)
                # If we are not multiplexing, there can be only one source
                # for merged_task
                m_connection = m_inputs.first.last

                if m_connection.source_port != connection.source_port
                    debug do
                        "rejected: sink #{m_connection.sink_port} is connected to a port "\
                        "named #{m_connection.source_port}, expected "\
                        "#{connection.source_port}"
                    end
                    return nil, m_connection
                end

                unless compatible_policies?(connection.policy, m_connection.policy)
                    debug do
                        "rejected: incompatible policies on #{connection.sink_port}"
                    end
                    return nil, m_connection
                end

                if m_connection.source_task == connection.source_task
                    [[], nil]
                else
                    [[connection, m_connection], nil]
                end
            end

            def merge_identical_tasks
                log_timepoint_group_start "syskit-merge-solver"
                dataflow_graph.enable_concrete_connection_graph
                log_timepoint_group "merge_task_contexts" do
                    merge_task_contexts
                end
                log_timepoint_group "merge_compositions" do
                    merge_compositions
                end
            ensure
                dataflow_graph.disable_concrete_connection_graph
                log_timepoint_group_end "syskit-merge-solver"
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

            def each_merge_leaf
                return enum_for(__method__) unless block_given?

                task_replacement_graph.each_vertex do |v|
                    yield(v) if task_replacement_graph.leaf?(v)
                end
            end
        end
    end
end
