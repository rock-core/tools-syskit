module Syskit
    module Runtime
        # Connection management at runtime
        class ConnectionManagement
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :plan


            def scheduler
                plan.execution_engine.scheduler
            end

            def initialize(plan)
                @plan = plan
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
                seen = Set.new

                # Remove first all tasks. Otherwise, removing some tasks will
                # also remove the new edges we just added
                for t in tasks
                    RequiredDataFlow.remove(t)
                end

                # Create the new connections
                for t in tasks
                    t.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                        next if seen.include?(source_task)
                        RequiredDataFlow.add_connections(source_task, t, [source_port, sink_port] => policy)
                    end
                    t.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        next if seen.include?(sink_task)
                        RequiredDataFlow.add_connections(t, sink_task, [source_port, sink_port] => policy)
                    end
                    seen << t
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
                    new[[source_task, sink_task]] = source_task[sink_task, RequiredDataFlow]
                end

                removed = Hash.new
                removed_edges.each do |source_task, sink_task|
                    removed[[source_task, sink_task]] = source_task[sink_task, ActualDataFlow].keys.to_set
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
                    new_mapping = source_task[sink_task, RequiredDataFlow]
                    old_mapping = source_task.orocos_task[sink_task.orocos_task, ActualDataFlow]

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

            def find_setup_syskit_task_context_from_orocos_task(orocos_task)
                klass = TaskContext.model_for(orocos_task.model)
                task = plan.find_tasks(klass.concrete_model).not_finishing.not_finished.
                    find { |t| t.setup? && (t.orocos_task == orocos_task) }
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
            
            # Remove port-to-port connections
            #
            # @param [{(Orocos::TaskContext,Orocos::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the actual tasks (NOT their Roby representations)
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_removal(removed)
                modified = Set.new
                # Remove connections first
                removed.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        debug do
                            debug "disconnecting #{source_task}:#{source_port}"
                            debug "     => #{sink_task}:#{sink_port}"
                            break
                        end

                        source = source_task.port(source_port, false)
                        sink   = sink_task.port(sink_port, false)

                        if syskit_source_task = find_setup_syskit_task_context_from_orocos_task(source_task)
                            syskit_source_task.removing_output_port_connection(source_port, sink_task, sink_port)
                        end
                        if syskit_sink_task = find_setup_syskit_task_context_from_orocos_task(sink_task)
                            syskit_sink_task.removing_input_port_connection(source_task, source_port, sink_port)
                        end

                        begin
                            if !source.disconnect_from(sink)
                                warn "while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port} returned false"
                                warn "I assume that the ports are disconnected, but this should not have happened"
                            end

                        rescue Orocos::NotFound => e
                            warn "error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                            warn "I am assuming that the disconnection is actually effective, since one port does not exist anymore"
                        rescue Orocos::ComError => e
                            warn "Communication error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                            warn "I am assuming that the source component is dead and that therefore the connection is actually effective"
                        end

                        if syskit_source_task
                            syskit_source_task.removed_output_port_connection(source_port, sink_task, sink_port)
                        end
                        if syskit_sink_task
                            syskit_sink_task.removed_input_port_connection(source_task, source_port, sink_port)
                        end

                        if ActualDataFlow.static?(source_task, source_port)
                            TaskContext.needs_reconfiguration << source_task.name
                        end
                        if ActualDataFlow.static?(sink_task, sink_port)
                            TaskContext.needs_reconfiguration << sink_task.name
                        end
                        ActualDataFlow.remove_connections(source_task, sink_task,
                                          [[source_port, sink_port]])

                        if syskit_source_task && !syskit_source_task.executable?
                            modified << syskit_source_task
                        end
                        if syskit_sink_task && !syskit_sink_task.executable?
                            modified << syskit_sink_task
                        end
                    end
                end
                modified
            end

            # Actually create new connections
            #
            # @param [{(Syskit::TaskContext,Syskit::TaskContext) => {[String,String] => Hash}}] removed
            #   the connections, specified between the Syskit tasks
            # @return [[Syskit::TaskContext]] the list of tasks whose connections have been modified
            def apply_connection_additions(new)
                # And create the new ones
                pending_tasks = Set.new
                new.each do |(from_task, to_task), mappings|
                    next if !from_task.orocos_task || !to_task.orocos_task

                    mappings.each do |(from_port, to_port), policy|
                        debug do
                            debug "connecting #{from_task}:#{from_port}"
                            debug "     => #{to_task}:#{to_port}"
                            debug "     with policy #{policy}"
                            break
                        end

                        begin
                            policy, _ = Kernel.filter_options(policy, Orocos::Port::CONNECTION_POLICY_OPTIONS)

                            from_syskit_port = from_task.find_output_port(from_port)
                            to_syskit_port   = to_task.find_input_port(to_port)
                            from_orocos_port = from_task.orocos_task.port(from_port)
                            to_orocos_port   = to_task.orocos_task.port(to_port)

                            from_task.adding_output_port_connection(from_syskit_port, to_syskit_port, policy)
                            to_task.adding_input_port_connection(from_syskit_port, to_syskit_port, policy)

                            begin
                                current_policy = from_task.orocos_task[to_task.orocos_task, ActualDataFlow][[from_port, to_port]]
                            rescue ArgumentError
                            end

                            from_orocos_port.connect_to(to_orocos_port, policy)

                            from_task.added_output_port_connection(from_syskit_port, to_syskit_port, policy)
                            to_task.added_input_port_connection(from_syskit_port, to_syskit_port, policy)

                            ActualDataFlow.add_connections(
                                from_task.orocos_task, to_task.orocos_task,
                                [from_port, to_port] => [policy, from_syskit_port.static?, to_syskit_port.static?],
                                force_update: true)

                        rescue Orocos::ComError
                            # The task will be aborted. Simply ignore
                        rescue Orocos::InterfaceObjectNotFound => e
                            if e.task == from_task.orocos_task && e.name == from_port
                                plan.engine.add_error(PortNotFound.new(from_task, from_port, :output))
                            else
                                plan.engine.add_error(PortNotFound.new(to_task, to_port, :input))
                            end

                        end
                    end
                    if !to_task.executable?
                        pending_tasks << to_task
                    end
                end
                pending_tasks
            end

            def mark_connected_pending_tasks_as_executable(pending_tasks)
                pending_tasks.each do |t|
                    if t.setup? && t.all_inputs_connected?
                        t.executable = nil
                        debug { "#{t} has all its inputs connected, set executable to nil and executable? = #{t.executable?}" }
                    else
                        scheduler.report_holdoff "some inputs are not yet connected, Syskit maintains its state to non-executable", t
                    end
                end
            end

            # Apply all connection changes on the system. The principle is to
            # use a transaction-based approach: i.e. either we apply everything
            # or nothing.
            #
            # See #compute_connection_changes for the format of +new+ and
            # +removed+
            #
            # Returns a false value if it could not apply the changes and a true
            # value otherwise.
            def apply_connection_changes(new, removed)
                if removed_connections_require_network_update?(removed)
                    plan.syskit_engine.force_update!
                    return new, removed
                end

                additions_held, additions_ready = Hash.new, Hash.new
                new.each do |(from_task, to_task), mappings|
                    hold, ready = mappings.partition do |(from_port, to_port), policy|
                        (!from_task.setup? && !from_task.concrete_model.find_output_port(from_port)) ||
                            (!to_task.setup? && !to_task.concrete_model.find_input_port(to_port))
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
                                    debug "    #{from_port} has not been created yet"
                                end
                                if !to_task.setup? && !to_task.concrete_model.find_output_port(to_port)
                                    debug "    #{to_port} has not been created yet"
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

                early_removal, late_removal = removed.partition do |(source_task, sink_task), _|
                    source_running = begin source_task.running?
                                     rescue Orocos::ComError
                                     end
                    sink_running   = begin sink_task.running?
                                     rescue Orocos::ComError
                                     end
                    !source_running || !sink_running
                end
                early_additions, late_additions = additions_ready.partition do |(source_task, sink_task), _|
                    source_running = begin source_task.orocos_task.running?
                                     rescue Orocos::ComError
                                     end
                    sink_running   = begin sink_task.orocos_task.running?
                                     rescue Orocos::ComError
                                     end
                    if !source_running || !sink_running
                        debug { "early adding connections from #{source_task} to #{sink_task}" }
                        true
                    else
                        debug do
                            debug "late adding connections from #{source_task} to #{sink_task}"
                            debug "  #{source_task.orocos_task} running: #{source_task.orocos_task.running?}"
                            debug "  #{sink_task.orocos_task} running: #{sink_task.orocos_task.running?}"
                            break
                        end
                        false
                    end
                end

                modified_tasks = apply_connection_removal(early_removal)
                modified_tasks |= apply_connection_additions(early_additions)

                if !additions_held.empty?
                    mark_connected_pending_tasks_as_executable(modified_tasks)
                    additions = additions_held.merge(Hash[late_additions]) { |key, mappings1, mappings2| mappings1.merge(mappings2) }
                    return additions, late_removal
                end

                modified_tasks |= apply_connection_removal(late_removal)
                modified_tasks |= apply_connection_additions(late_additions)
                mark_connected_pending_tasks_as_executable(modified_tasks)
                return Hash.new, Hash.new
            end

            def update
                tasks = Flows::DataFlow.modified_tasks

                tasks.delete_if do |t|
                    t.finished?
                end

                # The modifications to +tasks+ might have removed all input
                # connection. Make sure that in this case, executable? has been
                # reset to nil
                #
                # The normal workflow does not work in this case, as it is only
                # looking for tasks whose input connections have been modified
                tasks.each do |t|
                    if t.setup? && !t.executable? && t.plan == plan && t.all_inputs_connected?
                        t.executable = nil
                    end
                end

                if !tasks.empty?
                    if Flows::DataFlow.pending_changes
                        tasks.merge(Flows::DataFlow.pending_changes.first)
                    end
                    tasks.delete_if { |t| !t.plan }
                    main_tasks, proxy_tasks = tasks.partition { |t| t.plan == plan }
                    main_tasks = main_tasks.to_set
                    main_tasks.delete_if do |t|
                        !t.execution_agent ||
                            t.execution_agent.ready_to_die? ||
                            t.execution_agent.finished?
                    end

                    debug do
                        debug "computing data flow update from modified tasks"
                        for t in main_tasks
                            debug "  #{t}"
                        end
                        break
                    end

                    new, removed = compute_connection_changes(main_tasks)
                    # Make also sure we have no dangling orocos_task within the
                    # ActualDataFlow graph
                    present_tasks = plan.find_tasks(TaskContext).map(&:orocos_task).to_set
                    dangling_tasks = ActualDataFlow.enum_for(:each_vertex).find_all do |orocos_task|
                        !present_tasks.include?(orocos_task)
                    end
                    dangling_tasks.each do |parent_t|
                        parent_t.each_child_vertex(ActualDataFlow) do |child_t|
                            if !present_tasks.include?(child_t)
                                # NOTE: since the two tasks have been removed,
                                # they cannot be within the 'removed' set
                                # already
                                mappings = parent_t[child_t, ActualDataFlow]
                                removed[[parent_t, child_t]] = mappings.keys.to_set
                            end
                        end
                    end

                    if new
                        debug do
                            debug "  new connections:"
                            new.each do |(from_task, to_task), mappings|
                                debug "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                                debug "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                                mappings.each do |(from_port, to_port), policy|
                                    debug "      #{from_port}:#{to_port} #{policy}"
                                end
                            end
                            debug "  removed connections:"
                            debug "  disable debug display because it is unstable in case of process crashes"
                            #removed.each do |(from_task, to_task), mappings|
                            #    Engine.info "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                            #    Engine.info "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                            #    mappings.each do |from_port, to_port|
                            #        Engine.info "      #{from_port}:#{to_port}"
                            #    end
                            #end
                                
                            break
                        end

                        Flows::DataFlow.pending_changes = [main_tasks, new, removed]
                        Flows::DataFlow.modified_tasks.clear
                        Flows::DataFlow.modified_tasks.merge(proxy_tasks.to_set)
                    else
                        debug "cannot compute changes, keeping the tasks queued"
                    end
                end

                if Flows::DataFlow.pending_changes
                    main_tasks, new, removed = Flows::DataFlow.pending_changes

                    debug "applying pending changes from the data flow graph"
                    new, removed = apply_connection_changes(new, removed)
                    if new.empty? && removed.empty?
                        Flows::DataFlow.pending_changes = nil
                    else
                        Flows::DataFlow.pending_changes = [main_tasks, new, removed]
                    end

                    if !Flows::DataFlow.pending_changes
                        debug "successfully applied pending changes"
                    else
                        debug "failed to apply pending changes"
                    end
                end
            end
        end
    end
end

