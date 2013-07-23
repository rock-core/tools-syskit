module Syskit
    module Runtime
        # Connection management at runtime
        class ConnectionManagement
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :plan

            attr_predicate :dry_run?, true

            def initialize(plan)
                @plan = plan
            end

            def self.update(plan, dry_run = false)
                manager = ConnectionManagement.new(plan)
                manager.dry_run = dry_run
                manager.update
            end

            # Updates an intermediate graph (Syskit::RequiredDataFlow) where
            # we store the concrete connections. We don't try to be smart:
            # remove all tasks that have to be updated and add their connections
            # again
            def update_required_dataflow_graph(tasks)
                seen = ValueSet.new

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
                if dry_run?
                    return [], []
                end

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

                    if !new_connections.empty?
                        new[[source_task, sink_task]] = new_connections
                    end
                    if !removed_connections.empty?
                        removed[[source_task.orocos_task, sink_task.orocos_task]] = removed_connections
                    end
                end

                return new, removed
            end

            # Adds source_task (resp. sink_task) to +set+ if modifying
            # connection specified in +mappings+ will require source_task (resp.
            # sink_task) to be restarted.
            #
            # Restart is required by having the task's input ports marked as
            # 'static' in the oroGen specification
            def update_restart_set(set, source_task, sink_task, mappings)
                if !set.include?(source_task)
                    needs_restart = mappings.any? do |source_port, sink_port|
                        begin
                            source_task.running? && source_task.model.find_output_port(source_port).static?
                        rescue Orocos::ComError
                        end
                    end
                    if needs_restart
                        set << source_task
                    end
                end

                if !set.include?(sink_task)
                    needs_restart =  mappings.any? do |source_port, sink_port|
                        begin
                            sink_task.running? && sink_task.model.find_input_port(sink_port).static?
                        rescue Orocos::ComError
                        end
                    end

                    if needs_restart
                        set << sink_task
                    end
                end
                set
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
                restart_tasks = ValueSet.new

                # Don't do anything if some of the connection changes are
                # between static ports and the relevant tasks are running
                #
                # Moreover, we check that the tasks are ready to be connected.
                # We do it only for the new set, as the removed connections are
                # obviously between tasks that can be connected ;-)
                new.each do |(source, sink), mappings|
                    if !dry_run?
                        if !sink.setup? || !source.setup?
                            debug do
                                debug "cannot modify connections from #{source}, either one is not yet set up"
                                debug "  to #{sink}"
                                debug "  source.executable?:      #{source.executable?}"
                                debug "  source.ready_for_setup?: #{source.ready_for_setup?}"
                                debug "  source.setup?:           #{source.setup?}"
                                debug "  sink.executable?:        #{sink.executable?}"
                                debug "  sink.ready_for_setup?:   #{sink.ready_for_setup?}"
                                debug "  sink.setup?:             #{sink.setup?}"
                                break
                            end
                            throw :cancelled
                        end
                    end

                    update_restart_set(restart_tasks, source, sink, mappings.keys)
                end

                restart_task_proxies = ValueSet.new
                removed.each do |(source, sink), mappings|
                    update_restart_set(restart_task_proxies, source, sink, mappings)
                end
                restart_task_proxies.each do |corba_handle|
                    klass = TaskContext.model_for(corba_handle.model)
                    task = plan.find_tasks(klass).running.
                        find { |t| t.orocos_name == corba_handle.name }

                    if task
                        restart_tasks << task
                    end
                end

                if !restart_tasks.empty?
                    new_tasks = Array.new
                    all_stopped = Roby::AndGenerator.new

                    restart_tasks.each do |task|
                        debug { "restarting #{task}" }
                        replacement = plan.recreate(task)
                        debug { "  replaced by #{replacement}" }
                        new_tasks << replacement
                        all_stopped << task.stop_event
                    end
                    new_tasks.each do |new_task|
                        all_stopped.add_causal_link new_task.start_event
                    end
                    throw :cancelled, all_stopped
                end

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

                        ActualDataFlow.remove_connections(source_task, sink_task,
                                          [[source_port, sink_port]])

                        # The following test is meant to make sure that we
                        # cleanup input ports after crashes. CORBA connections
                        # will properly cleanup the output port-to-corba part
                        # automatically, but never the corba-to-input port
                        #
                        # It will break code that connects to input ports
                        # externally. This is not a common case however.
                        # begin
                        #     if !ActualDataFlow.has_in_connections?(sink_task, sink_port)
                        #         debug { "calling #disconnect_all on the input port #{sink_task.name}:#{sink_port} since it has no input connections anymore" }
                        #         sink.disconnect_all
                        #     end
                        # rescue Orocos::NotFound
                        # rescue CORBA::ComError
                        # end
                    end
                end

                # And create the new ones
                pending_tasks = ValueSet.new
                new.each do |(from_task, to_task), mappings|
                    # The task might have been killed while the connections
                    # were already added to the data flow graph. Roby's GC will
                    # deal with that. Ignore.
                    next if !from_task.orocos_task
                    next if !to_task.orocos_task

                    mappings.each do |(from_port, to_port), policy|
                        debug do
                            debug "connecting #{from_task}:#{from_port}"
                            debug "     => #{to_task}:#{to_port}"
                            debug "     with policy #{policy}"
                            break
                        end

                        begin
                            policy, _ = Kernel.filter_options(policy, Orocos::Port::CONNECTION_POLICY_OPTIONS)
                            from_task.orocos_task.port(from_port).connect_to(to_task.orocos_task.port(to_port), policy)
                            ActualDataFlow.add_connections(from_task.orocos_task, to_task.orocos_task,
                                                       [from_port, to_port] => policy)
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

                # Tasks' executable flag is forcefully set to false until (1)
                # they are configured and (2) all static inputs are connected
                #
                # Check tasks for which we created an input. If they are not
                # executable and all_inputs_connected? returns true, set their
                # executable flag to nil
                debug do
                    debug "#{pending_tasks.size} pending tasks"
                    pending_tasks.each do |t|
                        debug "  #{t}: all_inputs_connected=#{t.all_inputs_connected?} executable=#{t.executable?}"
                    end
                    break
                end

                pending_tasks.each do |t|
                    if t.all_inputs_connected?
                        t.executable = nil
                        debug { "#{t} has all its inputs connected, set executable to nil and executable? = #{t.executable?}" }
                    end
                end

                true
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
                    # If there are some tasks that have been GCed/killed, we still
                    # need to update the connection graph to remove the old
                    # connections.  However, we should remove these tasks now as they
                    # should not be passed to compute_connection_changes
                    main_tasks, proxy_tasks = tasks.partition { |t| t.plan == plan }
                    main_tasks = main_tasks.to_value_set
                    if Flows::DataFlow.pending_changes
                        main_tasks.merge(Flows::DataFlow.pending_changes.first)
                    end

                    main_tasks.delete_if { |t| !t.plan || !t.execution_agent || t.execution_agent.ready_to_die? || t.execution_agent.finished? }
                    proxy_tasks.delete_if { |t| !t.plan }

                    debug do
                        debug "computing data flow update from modified tasks"
                        for t in main_tasks
                            debug "  #{t}"
                        end
                        break
                    end

                    new, removed = compute_connection_changes(main_tasks)
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

                        pending_replacement =
                            if Flows::DataFlow.pending_changes
                                Flows::DataFlow.pending_changes[3]
                            end

                        Flows::DataFlow.pending_changes = [main_tasks, new, removed, pending_replacement]
                        Flows::DataFlow.modified_tasks.clear
                        Flows::DataFlow.modified_tasks.merge(proxy_tasks.to_value_set)
                    else
                        debug "cannot compute changes, keeping the tasks queued"
                    end
                end

                if Flows::DataFlow.pending_changes
                    _, new, removed, pending_replacement = Flows::DataFlow.pending_changes
                    if pending_replacement && !pending_replacement.happened? && !pending_replacement.unreachable?
                        debug "waiting for replaced tasks to stop"
                    else
                        if pending_replacement
                            debug "successfully started replaced tasks, now applying pending changes"
                            pending_replacement.clear_vertex
                            plan.unmark_permanent(pending_replacement)
                        end

                        pending_replacement = catch :cancelled do
                            debug "applying pending changes from the data flow graph"
                            apply_connection_changes(new, removed)
                            Flows::DataFlow.pending_changes = nil
                        end

                        if !Flows::DataFlow.pending_changes
                            debug "successfully applied pending changes"
                        elsif pending_replacement
                            debug "waiting for replaced tasks to stop"
                            plan.add_permanent(pending_replacement)
                            Flows::DataFlow.pending_changes[3] = pending_replacement
                        else
                            debug "failed to apply pending changes"
                        end
                    end
                end
            end
        end
    end
end

