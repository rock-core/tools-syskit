module Syskit
    module Runtime
        def self.start_task_setup(task)
            execution_engine = task.execution_engine
            promise = execution_engine.promise(description: "setup of #{task}") { }
            promise = task.setup(promise).
                on_success(description: "#{task}#setup_successful") do
                    task.setup_successful!
                end

            task.setting_up!(promise)
            promise
        end

        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update_task_states(plan) # :nodoc:
            query = plan.find_tasks(Syskit::TaskContext).not_finished
            for t in query
                # The task's deployment is not started yet
                if !t.orocos_task
                    plan.execution_engine.scheduler.report_holdoff "did not configure, execution agent not started yet", t
                    next
                elsif t.execution_agent.aborted_event.pending?
                    next
                elsif !t.execution_agent
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

                if t.pending? && !t.setup? && !t.setting_up?
                    if t.ready_for_setup? && Syskit.conf.auto_configure?
                        start_task_setup(t)
                        next
                    else
                        plan.execution_engine.scheduler.report_holdoff "did not configure, not ready for setup", t
                    end
                end

                next if !t.running? && !t.starting? || t.aborted_event.pending?

                handled_this_cycle = Array.new
                begin
                    state = nil
                    state_count = 0
                    while (!state || t.orocos_task.runtime_state?(state)) && (new_state = t.update_orogen_state)
                        state_count += 1

                        # Returns nil if we have a communication problem. In this
                        # case, #update_orogen_state will have emitted the right
                        # events for us anyway
                        if new_state && handled_this_cycle.last != new_state
                            t.handle_state_changes
                            handled_this_cycle << new_state
                        end
                    end


                    if state_count >= Deployment::STATE_READER_BUFFER_SIZE
                        Runtime.warn "got #{state_count} state updates for #{t}, we might have lost some state updates in the process"
                    end

                rescue Orocos::CORBA::ComError => e
                    t.aborted_event.emit e
                end
            end
        end
    end
end

