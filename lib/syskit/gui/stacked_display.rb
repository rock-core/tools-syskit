require 'syskit/gui/plan_display'
module Ui
    # A Qt::ToolBox-based widget that has some convenience functions to display
    # Roby::Plan objects using the PlanDisplay widget
    class StackedDisplay < Qt::ToolBox
        attr_reader :task_mappings

        def initialize(parent = nil)
            super

            @task_mappings = Hash.new
        end

        # Removes all existing displays
        def clear
            while count > 0
                removeItem(0)
            end
        end

        # Adds a PlanDisplay widget with the given title and parameters
        def push_plan(title, mode, plan, engine, options)
            display = Ui::PlanDisplay.new(self)

            display.connect(SIGNAL('updated(QVariant&)')) do |error|
                emit updated(title, error)
            end
            display.plan = Roby::Plan.new
            task_mappings[display] = plan.deep_copy_to(display.plan)
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

        # Signal emitted when a plan display embedded in this widget is updated.
        # The string is the display title. If the variant is valid, it contains
        # an error that has been caught during the update
        signals 'updated(QString,QVariant&)'
    end
end

