module Syskit::GUI
    module ModelViews
        class TaskContext < Component
            def render(model)
                page.push(nil, "<p><b>oroGen name:</b> #{model.orogen_model.name}</p>")
                super
            end

            def plan_display_options
                Hash[:remove_compositions => nil, :annotations => ['task_info', 'port_details'].to_set]
            end
        end
    end
end

