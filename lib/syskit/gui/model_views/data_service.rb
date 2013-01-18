module Syskit::GUI
    module ModelViews
        class DataService < Component
            def plan_display_options
                Hash[:annotations => ['task_info', 'port_details'].to_set]
            end
        end
    end
end
