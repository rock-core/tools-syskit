module Syskit
    module Runtime
        # Connection management at runtime
        class ConnectionManagement
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :plan

            attr_reader :dataflow_graph

            def scheduler
                plan.execution_engine.scheduler
            end

            def log_timepoint_group(name, &block)
                plan.execution_engine.log_timepoint_group(name, &block)
            end

            def initialize(plan)
                @plan = plan
                @dataflow_graph = plan.task_relation_graph_for(Flows::DataFlow)
                @orocos_task_to_syskit_tasks = Hash.new
                @orocos_task_to_setup_syskit_task = Hash.new
                plan.find_tasks(Syskit::TaskContext).each do |t|
                    (@orocos_task_to_syskit_tasks[t.orocos_task] ||= []) << t
                    if t.setup?
                        @orocos_task_to_setup_syskit_task[t.orocos_task] = t
                    end
                end
            end

            def self.update(plan)
                manager = ConnectionManagement.new(plan)
                manager.update
            end

            # Updates an intermediate graph (Syskit::RequiredDataFlow) where
            # we store the concrete connections. We don't try to be smart:
            # remove all tasks that have to be updated and add their connections
            # again
            def update_required_dataflow_graph(tasks)
                tasks = tasks.to_set

                # Remove first all tasks. Otherwise, removing some tasks will
                # also remove the new edges we just added
                tasks.each do |t|
                    RequiredDataFlow.remove_vertex(t)
                end

                # Create the new connections
                #
                # We're only updating on a partial set of tasks ... so we do
                # have to enumerate both output and input connections. We can
                # however avoid doulbing work by avoiding the update of sink
                # tasks that are part of the set
                tasks.each do |t|
                    t.each_concrete_input_connection do |source_t, source_p, sink_p, policy|
                        policy = dataflow_graph.policy_graph
                                               .fetch([source_t, t], {})
                                               .fetch([source_p, sink_p], policy)

                        RequiredDataFlow.add_connections(
                            source_t, t,
                            [source_p, sink_p] => policy
                        )
                    end
                    t.each_concrete_output_connection do |source_p, sink_p, sink_t, policy|
                        next if tasks.include?(sink_t)

                        policy = dataflow_graph.policy_graph
                                               .fetch([t, sink_t], {})
                                               .fetch([source_p, sink_p], policy)
                        RequiredDataFlow.add_connections(
                            t, sink_t,
                            [source_p, sink_p] => policy
                        )
                    end
                end
            end

            # Computes the connection changes that are required to make the
            # required connections (declared in the DataFlow relation) match the
            # actual ones (on the underlying modules)
            #
            # It returns nil if the change can't be computed because the Roby
            # tasks are not tied to an underlying RTT task context.
            #
            # Returns [new, removed] where
            #
            #   new = { [from_task, to_task] => { [from_port, to_port] => policy, ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Syskit::TaskContext (i.e. Roby tasks), +from_port+ and
            # +to_port+ are the port names (i.e. strings) and policy the policy
            # hash that Orocos::OutputPort#connect_to expects.
            #
            #   removed = { [from_task, to_task] => { [from_port, to_port], ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Orocos::TaskContext (i.e. the underlying RTT tasks). +from_port+ and
            # +to_port+ are the names of the ports that have to be disconnected
            # (i.e. strings)
            def compute_connection_changes(tasks)
                not_running = tasks.find_all { |t| !t.orocos_task }
                if !not_running.empty?
                    debug do
                        debug "not computing connections because the deployment of the following tasks is not yet ready"
                        tasks.each do |t|
                            debug "  #{t}"
                        end
                        break
                    end
                    return
                end

                update_required_dataflow_graph(tasks)
                new_edges, removed_edges, updated_edges =
                    RequiredDataFlow.difference(ActualDataFlow, tasks, &:orocos_task)

                new = Hash.new
                new_edges.each do |source_task, sink_task|
                    new[[source_task, sink_task]] = RequiredDataFlow.edge_info(source_task, sink_task)
                end

                removed = Hash.new
                removed_edges.each do |source_task, sink_task|
                    removed[[source_task, sink_task]] = ActualDataFlow.edge_info(source_task, sink_task).keys.to_set
                end

                # We have to work on +updated+. The graphs are between tasks,
                # not between ports because of how ports are handled on both the
                # orocos.rb and Roby sides. So we must convert the updated
                # mappings into add/remove pairs. Moreover, to update a
                # connection policy we need to disconnect and reconnect anyway.
                #
                # Note that it is fine from a performance point of view, as in
                # most cases one removes all connections from two components to
                # recreate other ones between other components
                updated_edges.each do |source_task, sink_task|
                    new_mapping = RequiredDataFlow.edge_info(source_task, sink_task)
                    old_mapping = ActualDataFlow.edge_info(source_task.orocos_task, sink_task.orocos_task)

                    new_connections     = Hash.new
                    removed_connections = Set.new
                    new_mapping.each do |ports, new_policy|
                        if old_policy = old_mapping[ports]
                            if old_policy != new_policy
                                new_connections[ports] = new_policy
                                removed_connections << ports
                            end
                        else
                            new_connections[ports] = new_policy
                        end
                    end
                    old_mapping.each_key do |ports|
                        if !new_mapping.has_key?(ports)
                            removed_connections << ports
                        end
                    end

                    if !new_connections.empty?
                        new[[source_task, sink_task]] = new_connections
                    end
                    if !removed_connections.empty?
                        removed[[source_task.orocos_task, sink_task.orocos_task]] = removed_connections
                    end
                end

                return new, removed
            end

            # Returns the Syskit::TaskContext in the plan that manages an orocos task
            #
            # @return [nil,Syskit::TaskContext]
            def find_setup_syskit_task_context_from_orocos_task(orocos_task)
                @orocos_task_to_setup_syskit_task[orocos_task]
            end

            # Checks whether the removal of some connections require to run the
            # Syskit deployer right away
            #
            # @param [{(Orocos::TaskContext,Orocos::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the actual tasks (NOT their Roby representations)
            def removed_connections_require_network_update?(connections)
                unneeded_tasks = nil
                handle_modified_task = lambda do |orocos_task|
                    if !(syskit_task = find_setup_syskit_task_context_from_orocos_task(orocos_task))
                        return false
                    end

                    unneeded_tasks ||= plan.unneeded_tasks
                    if !unneeded_tasks.include?(syskit_task)
                        return true
                    end
                end

                connections.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        if ActualDataFlow.static?(source_task, source_port) && handle_modified_task[source_task]
                            debug { "#{source_task} has an outgoing connection removed from #{source_port} and the port is static" }
                            return true
                        elsif ActualDataFlow.static?(sink_task, sink_port) && handle_modified_task[sink_task]
                            debug { "#{sink_task} has an outgoing connection removed from #{sink_port} and the port is static" }
                            return true
                        end
                    end
                end
                false
            end


            def pre_disconnect(removed)
                removed.flat_map do |(source_task, sink_task), mappings|
                    mappings.map do |source_port, sink_port|
                        debug do
                            debug "disconnecting #{source_task}:#{source_port}"
                            debug "     => #{sink_task}:#{sink_port}"
                            break
                        end

                        if syskit_source_task = find_setup_syskit_task_context_from_orocos_task(source_task)
                            syskit_source_task.removing_output_port_connection(source_port, sink_task, sink_port)
                        end
                        if syskit_sink_task = find_setup_syskit_task_context_from_orocos_task(sink_task)
                            syskit_sink_task.removing_input_port_connection(source_task, source_port, sink_port)
                        end

                        [syskit_source_task, source_task, source_port, syskit_sink_task, sink_task, sink_port]
                    end
                end
            end

            def perform_disconnections(disconnections)
                success, failure = Concurrent::Array.new, Concurrent::Array.new
                port_cache = Concurrent::Map.new
                promises = disconnections.map do |syskit_from_task, from_task, from_port, syskit_to_task, to_task, to_port|
                    execution_engine = plan.execution_engine
                    execution_engine.promise(description: "disconnect #{from_task.name}##{from_port} -> #{to_task.name}##{to_port}") do
                        begin
                            from_orocos_port =
                                (port_cache[[from_task, from_port]] ||= from_task.raw_port(from_port))
                            to_orocos_port   =
                                (port_cache[[to_task, to_port]] ||= to_task.raw_port(to_port))
                            if !from_orocos_port.disconnect_from(to_orocos_port)
                                warn "while disconnecting #{from_task}:#{from_port} => #{to_task}:#{to_port} returned false"
                                warn "I assume that the ports are disconnected, but this should not have happened"
                            end
                            execution_engine.log(:syskit_disconnect, from_task.name, from_port, to_task.name, to_port)

                            success << [syskit_from_task, from_task, from_port, syskit_to_task, to_task, to_port]
                        rescue Exception => e
                            failure << [syskit_from_task, from_task, from_port, syskit_to_task, to_task, to_port, e]
                        end
                    end
                end
                log_timepoint_group 'apply_remote_disconnections' do
                    promises.each(&:execute)
                end
                # This is cheating around the "do not allow blocking calls in
                # main thread" principle. It's good because it parallelizes
                # disconnection - which speeds up network setup quite a bit - but
                # it's still blocking if one of the connections are blocking
                #
                # The "blocking calls should not affect Syskit" tests should
                # catch this
                promises.each { |p| p.promise.value! }
                return success, failure
            end

            def post_disconnect_success(disconnections)
                modified = Set.new
                disconnections.each do |syskit_from_task, from_task, from_port, syskit_to_task, to_task, to_port|
                    if syskit_from_task
                        syskit_from_task.removed_output_port_connection(
                            from_port, to_task, to_port)
                    end
                    if syskit_to_task
                        syskit_to_task.removed_input_port_connection(
                            from_task, from_port, to_port)
                    end

                    if ActualDataFlow.static?(from_task, from_port)
                        if syskit_from_task
                            syskit_from_task.needs_reconfiguration!
                        else
                            Deployment.needs_reconfiguration!(plan, from_task.name)
                        end
                    end
                    if ActualDataFlow.static?(to_task, to_port)
                        if syskit_to_task
                            syskit_to_task.needs_reconfiguration!
                        else
                            Deployment.needs_reconfiguration!(plan, to_task.name)
                        end
                    end
                    ActualDataFlow.remove_connections(from_task, to_task,
                                                      [[from_port, to_port]])

                    if syskit_from_task && !syskit_from_task.executable?
                        modified << syskit_from_task
                    end
                    if syskit_to_task && !syskit_to_task.executable?
                        modified << syskit_to_task
                    end
                end
                modified
            end

            def post_disconnect_failure(disconnections)
                disconnections.find_all do |syskit_from_task, from_task, from_port, syskit_to_task, to_task, to_port, error|

                    case error
                    when Orocos::ComError, Orocos::NotFound
                        terminating_deployments =
                            plan.find_tasks(Syskit::Deployment).finishing.
                            flat_map { |d| d.remote_task_handles.values }

                        if !terminating_deployments.include?(from_task) && !terminating_deployments.include?(to_task)
                            warn "error while disconnecting #{from_task}:#{from_port} => #{to_task}:#{to_port}: #{error.message}"
                            warn "I am assuming that the disconnection is actually effective, since one port does not exist anymore and/or the task cannot be contacted (i.e. assumed to be dead)"
                        end
                        true
                    else
                        plan.execution_engine.add_framework_error(error, "connection management")
                        false
                    end
                end
            end

            # Remove port-to-port connections
            #
            # @param [{(Orocos::TaskContext,Orocos::TaskContext) => [[String,String]]}] removed
            #   the connections, specified between the actual tasks (NOT their Roby representations)
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_removal(removed)
                disconnections = pre_disconnect(removed)
                success, failure = perform_disconnections(disconnections)
                spurious_failures = post_disconnect_failure(failure)
                post_disconnect_success(success + spurious_failures)
            end

            # Actually create new connections
            #
            # @param [{(Syskit::TaskContext,Syskit::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the Syskit tasks
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_additions(new)
                actual_connections = pre_connect(new)
                performed_connections, failed_connections = perform_connections(actual_connections)
                post_connect_success(performed_connections)
                post_connect_failure(failed_connections)
                new.map { |(_, to_task), mappings| to_task if !to_task.executable? }.
                    compact
            end

            def pre_connect(new)
                # And create the new ones
                new.flat_map do |(from_task, to_task), mappings|
                    mappings.map do |(from_port, to_port), policy|
                        debug do
                            debug "connecting #{from_task}:#{from_port}"
                            debug "     => #{to_task}:#{to_port}"
                            debug "     with policy #{policy}"
                            break
                        end

                        policy, _ = Kernel.filter_options(policy, Orocos::Port::CONNECTION_POLICY_OPTIONS)

                        from_syskit_port = from_task.find_output_port(from_port)
                        to_syskit_port   = to_task.find_input_port(to_port)

                        from_task.adding_output_port_connection(from_syskit_port, to_syskit_port, policy)
                        to_task.adding_input_port_connection(from_syskit_port, to_syskit_port, policy)

                        distance = from_task.distance_to(to_task)

                        [from_task, from_port, to_task, to_port, policy, distance]
                    end
                end
            end

            # Actually perform the connections
            #
            # It logs a :syskit_connect event at the end of the connection call.
            # It is formatted as:
            #
            #     syskit_connect(:success,
            #       source_task_orocos_name, source_port_name,
            #       sink_task_orocos_name, sink_task_name,
            #       policy)
            #
            # or
            #
            #     syskit_connect(:failure,
            #       source_task_orocos_name, source_port_name,
            #       sink_task_orocos_name, sink_task_name,
            #       policy, exception)
            #
            # @param [Array] the connections to be created, as returned by
            #   {#pre_connect}
            # @return [(Array,Array)] the successful and failed connections, in
            #   the same format than the connection argument for the success
            #   array. The failure array gets in addition the exception as last
            #   argument.
            def perform_connections(connections)
                success, failure = Concurrent::Array.new, Concurrent::Array.new
                port_cache = Concurrent::Map.new
                promises = connections.map do |from_task, from_port, to_task, to_port, policy, distance|
                    execution_engine = plan.execution_engine
                    execution_engine.promise(description: "connect #{from_task.orocos_name}##{from_port} -> #{to_task.orocos_name}##{to_port}") do
                        begin
                            from_orocos_port =
                                (port_cache[[from_task, from_port]] ||= from_task.orocos_task.raw_port(from_port))
                            to_orocos_port   =
                                (port_cache[[to_task, to_port]] ||= to_task.orocos_task.raw_port(to_port))
                            from_orocos_port.connect_to(to_orocos_port, distance: distance, **policy)
                            execution_engine.log(:syskit_connect, :success, from_task.orocos_name, from_port, to_task.orocos_name, to_port, policy)
                            success << [from_task, from_port, to_task, to_port, policy]
                        rescue Exception => e
                            execution_engine.log(:syskit_connect, :failure, from_task.orocos_name, from_port, to_task.orocos_name, to_port, policy)
                            failure << [from_task, from_port, to_task, to_port, policy, e]
                        end
                    end
                end
                log_timepoint_group 'apply_remote_connections' do
                    promises.each(&:execute)
                end
                # This is cheating around the "do not allow blocking calls in
                # main thread" principle. It's good because it parallelizes
                # connection - which speeds up network setup quite a bit - but
                # it's still blocking if one of the connections are blocking
                #
                # The "blocking calls should not affect Syskit" tests should
                # catch this
                promises.each { |p| p.promise.value! }
                return success, failure
            end

            def post_connect_success(connections)
                connections.each do |from_task, from_port, to_task, to_port, policy|
                    from_syskit_port = from_task.find_output_port(from_port)
                    to_syskit_port   = to_task.find_input_port(to_port)
                    from_task.added_output_port_connection(from_syskit_port, to_syskit_port, policy)
                    to_task.added_input_port_connection(from_syskit_port, to_syskit_port, policy)

                    ActualDataFlow.add_connections(
                        from_task.orocos_task, to_task.orocos_task,
                        [from_port, to_port] => [policy, from_syskit_port.static?, to_syskit_port.static?],
                        force_update: true)
                end
            end

            def post_connect_failure(connections)
                connections.each do |from_task, from_port, to_task, to_port, policy, error|
                    case error
                    when Orocos::InterfaceObjectNotFound
                        if error.task == from_task.orocos_task && error.name == from_port
                            plan.execution_engine.add_error(PortNotFound.new(from_task, from_port, :output))
                        else
                            plan.execution_engine.add_error(PortNotFound.new(to_task, to_port, :input))
                        end
                    else
                        plan.execution_engine.add_error(Roby::CodeError.new(error, to_task))
                    end
                end
            end

            def mark_connected_pending_tasks_as_executable(pending_tasks)
                pending_tasks.each do |t|
                    if !t.setup?
                        scheduler.report_holdoff "not yet configured", t
                    elsif !t.start_only_when_connected?
                        t.ready_to_start!
                    elsif t.all_inputs_connected?
                        t.ready_to_start!
                        debug do
                            "#{t} has all its inputs connected, set executable "\
                            "to nil and executable? = #{t.executable?}"
                        end
                        scheduler.report_action(
                            "all inputs connected, marking as ready to start", t)
                    else
                        scheduler.report_holdoff(
                            "waiting for all inputs to be connected", t)
                    end
                end
            end

            # Partition a set of connections between the ones that can be
            # performed right now, and those that must wait for the involved
            # tasks' state to change
            #
            # @param connections the connections, specified as
            #            (source_task, sink_task) => Hash[
            #               (source_port, sink_port) => policy,
            #               ...]
            #
            #   note that the source and sink task type are unspecified.
            #
            # @param [Hash<Object,Symbol>] a cache of the task states, as a
            #   mapping from a source/sink task object as used in the
            #   connections hash to the state name
            # @param [String] the kind of operation that will be done. It is
            #   purely used to display debugging information
            # @param [#[]] an object that maps the objects used as tasks in
            #   connections and states to an object that responds to
            #   {#rtt_state}, to evaluate the object's state.
            # @return [Array,Hash] the set of connections that can be performed
            #   right away, and the set of connections that require a state change
            #   in the tasks
            def partition_early_late(connections, kind, to_syskit_task)
                early, late = connections.partition do |(source_task, sink_task), port_pairs|
                    source_is_running = (syskit_task = to_syskit_task[source_task]) && syskit_task.running?
                    sink_is_running   = (syskit_task = to_syskit_task[sink_task])   && syskit_task.running?
                    early = !source_is_running || !sink_is_running

                    debug do
                        debug "#{port_pairs.size} #{early ? 'early' : 'late'} #{kind} connections from #{source_task} to #{sink_task}"
                        debug "  source running?: #{source_is_running}"
                        debug "  sink   running?: #{sink_is_running}"
                        break
                    end
                    early
                end
                return early, Hash[late]
            end

            # Partition new connections between
            def new_connections_partition_held_ready(new)
                additions_held, additions_ready = Hash.new, Hash.new
                new.each do |(from_task, to_task), mappings|
                    if !from_task.execution_agent.ready? || !to_task.execution_agent.ready?
                        hold, ready = mappings, Hash.new
                    elsif from_task.setup? && to_task.setup?
                        hold, ready = Hash.new, mappings
                    else
                        hold, ready = mappings.partition do |(from_port, to_port), policy|
                            (!from_task.setup? && !from_task.concrete_model.find_output_port(from_port)) ||
                                (!to_task.setup? && !to_task.concrete_model.find_input_port(to_port))
                        end
                    end

                    if !hold.empty?
                        debug do
                            debug "holding #{hold.size} connections from "
                            log_pp :debug, from_task
                            debug "  setup?: #{from_task.setup?}"
                            log_pp :debug, to_task
                            debug "  setup?: #{to_task.setup?}"

                            hold.each do |(from_port, to_port), policy|
                                debug "  #{from_port} => #{to_port} [#{policy}]"
                                if !from_task.setup? && !from_task.concrete_model.find_output_port(from_port)
                                    debug "    output port #{from_port} is dynamic and the task is not yet configured"
                                end
                                if !to_task.setup? && !to_task.concrete_model.find_input_port(to_port)
                                    debug "    input port #{to_port} is dynamic and the task is not yet configured"
                                end
                            end
                            break
                        end
                        additions_held[[from_task, to_task]] = Hash[hold]
                    end

                    if !ready.empty?
                        debug do
                            debug "ready on #{from_task} => #{to_task}"
                            ready.each do |(from_port, to_port), policy|
                                debug "  #{from_port} => #{to_port} [#{policy}]"
                            end
                            break
                        end
                        additions_ready[[from_task, to_task]] = Hash[ready]
                    end
                end
                return additions_held, additions_ready
            end

            # Apply the connection changes that can be applied
            def apply_connection_changes(new, removed)
                additions_held, additions_ready = new_connections_partition_held_ready(new)

                early_removal, late_removal     =
                    partition_early_late(removed, 'removed', method(:find_setup_syskit_task_context_from_orocos_task))
                early_additions, late_additions =
                    partition_early_late(additions_ready, 'added', proc { |v| v })

                modified_tasks = Set.new
                log_timepoint_group 'early_disconnections' do
                    modified_tasks.merge apply_connection_removal(early_removal)
                end
                log_timepoint_group 'early_connections' do
                    modified_tasks.merge apply_connection_additions(early_additions)
                end

                if !additions_held.empty?
                    mark_connected_pending_tasks_as_executable(modified_tasks)
                    additions = additions_held.merge(late_additions) { |key, mappings1, mappings2| mappings1.merge(mappings2) }
                    return additions, late_removal
                end

                log_timepoint_group 'late_disconnections' do
                    modified_tasks.merge apply_connection_removal(late_removal)
                end
                log_timepoint_group 'late_connections' do
                    modified_tasks.merge apply_connection_additions(late_additions)
                end
                mark_connected_pending_tasks_as_executable(modified_tasks)
                return Hash.new, Hash.new
            end

            # @api private
            #
            # Compute the set of connections we should remove to account for
            # orocos tasks whose supporting syskit task has been removed, but
            # are still connected
            #
            # The result is formatted as the rest of the connection hashes, that
            # is keys are (source_task, sink_task) and values are Array<(source_port,
            # task_port)>. Note that source_task and sink_task are
            # Orocos::TaskContext, and it is guaranteed that one of them has no
            # equivalent in the Syskit graphs (meaning that no keys in the
            # return value can be found in the return value of
            # {#compute_connection_changes})
            #
            # @return [Hash]
            def dangling_task_cleanup
                removed = Hash.new
                ActualDataFlow.each_vertex do |parent_t|
                    unless @orocos_task_to_syskit_tasks.has_key?(parent_t)
                        ActualDataFlow.each_out_neighbour(parent_t) do |child_t|
                            mappings = ActualDataFlow.edge_info(parent_t, child_t)
                            removed[[parent_t, child_t]] = mappings.keys.to_set
                        end
                    end
                end
                removed
            end

            def active_task?(t)
                t.plan && !t.finished? && t.execution_agent &&
                    !t.execution_agent.finished? && !t.execution_agent.ready_to_die?
            end

            def update
                # Don't do anything if the engine is deploying
                return if plan.syskit_has_async_resolution?

                tasks = dataflow_graph.modified_tasks
                tasks.delete_if { |t| !active_task?(t) }
                debug "connection: updating, #{tasks.size} tasks modified in dataflow graph"

                # The modifications to +tasks+ might have removed all input
                # connection. Make sure that in this case, executable? has been
                # reset to nil
                #
                # The normal workflow does not work in this case, as it is only
                # looking for tasks whose input connections have been modified
                mark_connected_pending_tasks_as_executable(
                    tasks.reject(&:executable?))

                if !tasks.empty?
                    if dataflow_graph.pending_changes
                        dataflow_graph.pending_changes.first.each do |t|
                            tasks << t if active_task?(t)
                        end
                    end

                    # Auto-add any Syskit task that has the same underlying
                    # orocos task, or we might get inconsistencies
                    tasks = tasks.each_with_object(Set.new) do |t, s|
                        s.merge(@orocos_task_to_syskit_tasks[t.orocos_task])
                    end
                    tasks.delete_if { |t| !active_task?(t) }

                    debug do
                        debug "computing data flow update from modified tasks"
                        for t in tasks
                            debug "  #{t}"
                        end
                        break
                    end

                    new, removed = compute_connection_changes(tasks)
                    if new
                        dataflow_graph.pending_changes = [tasks.dup, new, removed]
                        dataflow_graph.modified_tasks.clear
                    else
                        debug "cannot compute changes, keeping the tasks queued"
                    end
                end

                dangling = dangling_task_cleanup
                if !dangling.empty?
                    dataflow_graph.pending_changes ||= [[], Hash.new, Hash.new]
                    dataflow_graph.pending_changes[2].merge!(dangling) do |k, m0, m1|
                        m0.merge(m1)
                    end
                end

                if dataflow_graph.pending_changes
                    main_tasks, new, removed = dataflow_graph.pending_changes
                    debug "#{main_tasks.size} tasks in pending"
                    main_tasks.delete_if { |t| !active_task?(t) }
                    debug "#{main_tasks.size} tasks after inactive removal"
                    new.delete_if do |(source_task, sink_task), _|
                        !active_task?(source_task) || !active_task?(sink_task)
                    end
                    if removed_connections_require_network_update?(removed)
                        dataflow_graph.pending_changes = [main_tasks, new, removed]
                        Runtime.apply_requirement_modifications(plan, force: true)
                        return
                    end

                    debug "applying pending changes from the data flow graph"
                    new, removed = apply_connection_changes(new, removed)
                    if new.empty? && removed.empty?
                        dataflow_graph.pending_changes = nil
                    else
                        dataflow_graph.pending_changes = [main_tasks, new, removed]
                    end

                    if !dataflow_graph.pending_changes
                        debug "successfully applied pending changes"
                    else
                        debug do
                            debug "some connection changes could not be applied in this pass"
                            main_tasks, new, removed = dataflow_graph.pending_changes
                            additions = new.inject(0) { |count, (_, ports)| count + ports.size }
                            removals  = removed.inject(0) { |count, (_, ports)| count + ports.size }
                            debug "  #{additions} new connections pending"
                            debug "  #{removals} removed connections pending"
                            debug "  involving #{main_tasks.size} tasks"
                            break
                        end
                    end
                end
            end
        end
    end
end
