module Syskit::GUI
    module ModelViews
        class TaskContext < Component
            attr_reader :orogen_rendering
            attr_reader :task_model_view

            def initialize(page)
                super(page)
                @task_model_view = Roby::GUI::ModelViews::Task.new(page)
                @orogen_rendering = Orocos::HTML::TaskContext.new(page)
            end

            def render(model, options = Hash.new)
                task_model_view.render(model)
                super

                page.push("oroGen Model", "<p><b>oroGen name:</b> #{model.orogen_model.name}</p>")
                orogen_rendering.render(model.orogen_model)
            end

            def plan_display_options
                Hash[:remove_compositions => nil, :annotations => ['task_info', 'port_details'].to_set]
            end
        end
    end
end

