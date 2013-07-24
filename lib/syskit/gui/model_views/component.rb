require 'syskit/gui/component_network_base_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a single component model. It is used to visualize the
        # taks contexts and data services
        class Component < ComponentNetworkBaseView
            def render(model, options = Hash.new)
                super

                task = instanciate_model(model)

                page.push_plan(
                    'Interface', 'dataflow',
                    task.plan, plan_display_options)
                render_data_services(task)
            end
        end
    end
end
