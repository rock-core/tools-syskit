require 'syskit/gui/component_network_base_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a single component model. It is used to visualize the
        # taks contexts and data services
        class Component < ComponentNetworkBaseView
            # Options for the display of the interface
            attr_reader :interface_options

            def initialize(page)
                super
                @interface_options = Hash[
                    :mode => 'dataflow',
                    :title => 'Interface',
                    :annotations => ['task_info', 'port_details'].to_set,
                    :zoom => 1]
            end

            def render(model, options = Hash.new)
                super

                task = instanciate_model(model)
                @plan = task.plan

                push_plan('interface', task.plan)
                render_data_services(task)
            end
        end
    end
end
