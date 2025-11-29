# frozen_string_literal: true

require "roby/schedulers/global"

module Syskit
    module Schedulers
        # Subclass of Roby's Global scheduler to handle Syskit-specific relations
        class Global < Roby::Schedulers::Global
            def non_executable_resolution_tasks(non_executable_task)
                return super if non_executable_task.abstract? ||
                                !non_executable_task.kind_of?(Component)

                graph = @plan.event_relation_graph_for(
                    Roby::EventStructure::SyskitConfigurationPrecedence
                )

                # a->b in the graph means that 'a' needs to happen for 'b' to be
                # configured, where 'b' is always the start event of a task
                related = graph.in_neighbours(non_executable_task.start_event).map do |ev|
                    ev.task if ev.respond_to?(:task)
                end

                super | related.compact
            end
        end
    end
end
