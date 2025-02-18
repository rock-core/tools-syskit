# frozen_string_literal: true

module Syskit
    # Common methods for network generation exception messages
    module NetworkGenerationsExceptionHelpers
        def find_all_related_syskit_actions(task, toplevel_tasks_to_requirements)
            result = []
            while task
                result.concat(toplevel_tasks_to_requirements[task] || [])
                task = task.each_parent_task.first
            end
            result
        end

        def print_dependent_definitions(pp, task, defs)
            return if defs.empty?

            pp.breakable
            pp.text "#{task} is needed by the following definitions:"
            pp.nest(2) do
                defs.each do |d|
                    pp.breakable
                    pp.text d.to_s
                end
            end
        end

        def print_failed_merge_chain(pp, task0, task1)
            solver = NetworkGeneration::MergeSolver.new(task0.plan)
            @merge_result = solver.resolve_merge(task0, task1, {})
            pp.breakable
            @merge_result.pretty_print_failure(pp)
        end
    end
end
