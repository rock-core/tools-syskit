require 'orocos/roby/gui/plan_display'
module Ui
    # A Qt::ToolBox-based widget that has some convenience functions to display
    # Roby::Plan objects using the PlanDisplay widget
    class StackedDisplay < Qt::ToolBox
        # Removes all existing displays
        def clear
            while count > 0
                removeItem(0)
            end
        end

        # Adds a PlanDisplay widget with the given title and parameters
        def push_plan(title, mode, plan, engine, options)
            display = Ui::PlanDisplay.new(self)
            display.plan = plan.dup
            display.mode = mode
            display.options = options
            display.display
            add_item(display, title)
            display
        end

        # Adds a plain Qt::Widget with the given title
        def push(title, widget)
            add_item(widget, title)
        end
    end
end
