module Syskit::GUI
    module ModelViews
        class DataService < Component
            def initialize(page)
                super(page)
                buttons = Array.new
                buttons.concat(self.class.common_graph_buttons('interface'))
                interface_options[:buttons] = buttons
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
