# frozen_string_literal: true

module Syskit
    module Runtime # :nodoc:
        # @api private
        #
        # Update the state of all unfinished tasks
        #
        # Called once per execution cycle by the engine
        def self.update_task_states(plan) # :nodoc:
            scheduler = plan.execution_engine.scheduler
            plan.find_tasks(Syskit::TaskContext).not_finished.each do |task|
                next if task.failed_to_start?

                handle_single_task_state_update(scheduler, task)
            end
        end

        # @api private
        #
        # Handle state changes for a single task
        def self.handle_single_task_state_update(scheduler, task)
            return unless handle_task_state_updates?(scheduler, task)

            handle_task_configuration(scheduler, task) unless task.setup?
            return if !task.running? && !task.starting?

            handle_task_runtime_states(task)
        end

        # @api private
        #
        # Handle a task that needs to be configured
        def self.handle_task_configuration(scheduler, task)
            if task.setting_up?
                scheduler.report_holdoff("is being configured", task)
                return
            end

            return unless scheduler.enabled?
            return unless task.meets_configurationg_precedence_constraints?

            task.freeze_delayed_arguments
            if task.ready_for_setup?
                task.setup.execute
            else
                scheduler.report_holdoff("did not configure, not ready for setup", task)
            end
        end

        # @api private
        #
        # Handle the runtime state changes coming from the oroGen component
        def self.handle_task_runtime_states(task)
            handled_this_cycle = []

            state = nil
            state_count = 0
            while (!state || task.orocos_task.runtime_state?(state)) &&
                  (new_state = task.update_orogen_state)
                state_count += 1

                # Returns nil if we have a communication problem. In this
                # case, #update_orogen_state will have emitted the right
                # events for us anyway
                if handled_this_cycle.last != new_state
                    task.handle_state_changes
                    handled_this_cycle << new_state
                end
            end

            warn_state_reader_overrun(state_count)
        end

        def self.warn_state_reader_overrun(state_count)
            return if state_count < Deployment::STATE_READER_BUFFER_SIZE

            Runtime.warn(
                "got #{state_count} state updates for #{task}, we might "\
                "have lost some state updates in the process"
            )
        end

        # Check if the task is in a state that allow us to process its state updates
        #
        # Of notice, we stop looking at tasks when we know the underlying process is
        # being killed. It has caused some deep freeze in OmniORB in the past.
        def self.handle_task_state_updates?(scheduler, task)
            execution_agent = task.execution_agent

            # Check if the task is ready
            if !task.orocos_task
                scheduler.report_holdoff(
                    "did not configure, execution agent not started yet", task
                )
                return
            elsif !execution_agent
                raise NotImplementedError,
                      "#{task} is not yet finished but has no execution agent. "\
                      "#{task}'s history is\n  #{task.history.map(&:to_s).join("\n  ")}"
            elsif !execution_agent.ready?
                raise InternalError,
                      "orocos_task != nil on #{task}, "\
                      "but #{execution_agent} is not ready yet"
            end

            # Some CORBA implementations (namely, omniORB) may behave weird
            # if the remote process terminates in the middle of a remote
            # call.
            #
            # Ignore tasks whose process is terminating to reduce the
            # likelihood of that happening
            return if execution_agent.finishing? || execution_agent.ready_to_die?

            true
        end
    end
end
