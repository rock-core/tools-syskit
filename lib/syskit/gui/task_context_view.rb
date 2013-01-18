require 'syskit/gui/component_model_view'
module Syskit
    module GUI
        class TaskContextView < ComponentModelView
            def render(model)
                super

                task = instanciate_model(model)

                plan_display_options = Hash[
                    :remove_compositions => false,
                    :annotations => ['task_info', 'port_details'].to_set
                ]
                push_plan('Task Dependency Hierarchy', 'hierarchy', task.plan, Roby.syskit_engine, plan_display_options)
                default_widget = push_plan('Dataflow', 'dataflow', task.plan, Roby.syskit_engine, plan_display_options)
                render_data_services(task)

                self.current_widget = default_widget
            end
        end
    end
end

