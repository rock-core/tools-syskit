# frozen_string_literal: true

require "syskit/gui/component_network_base_view"
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
                    mode: "dataflow",
                    title: "Interface",
                    annotations: %w[task_info port_details].to_set,
                    zoom: 1]
            end

            def render_doc(model)
                if model.doc
                    page.push nil, page.main_doc(model.doc)
                end
            end

            def render(model, doc: true, **push_options)
                if doc
                    render_doc(model)
                end

                super

                task = instanciate_model(model)
                @plan = task.plan

                push_plan("interface", task.plan, push_options)
                render_data_services(task)
            end
        end
    end
end
