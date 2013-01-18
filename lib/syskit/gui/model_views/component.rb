require 'syskit/gui/component_network_base_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a single component model. It is used to visualize the
        # taks contexts and data services
        class Component < ComponentNetworkBaseView
            def render(model)
                super

                task = instanciate_model(model)

                default_widget = push_plan(
                    'Interface', 'dataflow',
                    task.plan, Roby.syskit_engine, plan_display_options)
                render_data_services(task)

                self.current_widget = default_widget
            end
        end
    end
end
