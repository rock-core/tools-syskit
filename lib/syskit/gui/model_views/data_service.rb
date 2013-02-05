module Syskit::GUI
    module ModelViews
        class DataService < Component
            def plan_display_options
                Hash[:annotations => ['task_info', 'port_details'].to_set]
            end

            def list_services(task)
                services = super
                services.first.last.shift
                if services.first.last.empty?
                    Array.new
                else
                    services
                end
            end

            def render_data_services(task, with_names = false)
                super
            end
        end
    end
end
