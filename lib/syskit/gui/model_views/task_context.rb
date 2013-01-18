module Syskit::GUI
    module ModelViews
        class TaskContext < Component
            def plan_display_options
                Hash[:remove_compositions => nil, :annotations => ['task_info', 'port_details'].to_set]
            end
        end
    end
end

