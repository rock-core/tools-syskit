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
                options, push_options = Kernel.filter_options options,
                    :doc => true

                if options[:doc] && model.doc
                    page.push nil, page.main_doc(model.doc)
                end

                super

                task = instanciate_model(model)
                @plan = task.plan

                push_plan('interface', task.plan, push_options)
                render_data_services(task)
            end
        end
    end
end
