module Syskit::GUI
    module ModelViews
        class TaskContext < Component
            attr_reader :orogen_rendering

            def initialize(page)
                super(page)
                @orogen_rendering = Orocos::HTML::TaskContext.new(page)
            end

            def render(model)
                page.push(nil, "<p><b>oroGen name:</b> #{model.orogen_model.name}</p>")
                orogen_rendering.render(model.orogen_model)

                super
            end

            def plan_display_options
                Hash[:remove_compositions => nil, :annotations => ['task_info', 'port_details'].to_set]
            end
        end
    end
end

