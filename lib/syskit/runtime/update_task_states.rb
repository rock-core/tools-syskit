module Syskit
    module Runtime
        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update_task_states(plan) # :nodoc:
            all_dead_deployments = ValueSet.new
            for name, server in Syskit.process_servers
                server = server.first
                if dead_deployments = server.wait_termination(0)
                    dead_deployments.each do |p, exit_status|
                        d = Deployment.all_deployments[p]
                        if !d.finishing?
                            Syskit.warn "#{p.deployment_name} unexpectedly died on #{name}"
                        end
                        all_dead_deployments << d
                        d.dead!(exit_status)
                    end
                end
            end

            for deployment in all_dead_deployments
                deployment.cleanup_dead_connections
            end

            if !(query = plan.instance_variable_get :@orocos_update_query)
                query = plan.find_tasks(Syskit::TaskContext).
                    not_finished
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                # The task's deployment is not started yet
                next if !t.orocos_task

                if !t.execution_agent
                    raise NotImplementedError, "#{t} is not yet finished but has no execution agent. #{t}'s history is\n  #{t.history.map(&:to_s).join("\n  ")}"
                elsif !t.execution_agent.ready?
                    raise InternalError, "orocos_task != nil on #{t}, but #{t.execution_agent} is not ready yet"
                end

                # Some CORBA implementations (namely, omniORB) may behave weird
                # if the remote process terminates in the middle of a remote
                # call.
                #
                # Ignore tasks whose process is terminating to reduce the
                # likelihood of that happening
		if t.execution_agent.ready_to_die?
		    next
		end

                if t.pending? && !t.setup? 
                    if t.ready_for_setup? && Roby.app.orocos_auto_configure?
                        begin
                            t.setup 
                            t.is_setup!
                        rescue Exception => e
                            t.event(:start).emit_failed(e)
                        end
                        next
                    end
                end

                handled_this_cycle = Array.new
                next if !t.running?

                begin
                    state = nil
                    state_count = 0
                    while (!state || t.orocos_task.runtime_state?(state)) && t.update_orogen_state
                        state_count += 1
                        state = t.orocos_task

                        # Returns nil if we have a communication problem. In this
                        # case, #update_orogen_state will have emitted the right
                        # events for us anyway
                        if state && handled_this_cycle.last != state
                            t.handle_state_changes
                            handled_this_cycle << state
                        end
                    end


                    if state_count >= TaskContext::STATE_READER_BUFFER_SIZE
                        Engine.warn "got #{state_count} state updates for #{t}, we might have lost some state updates in the process"
                    end

                rescue Orocos::CORBA::ComError => e
                    t.emit :aborted, e
                end
            end
        end
    end
end

