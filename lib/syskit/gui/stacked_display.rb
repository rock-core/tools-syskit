require 'syskit/gui/plan_display'
module Syskit
    module GUI
        # A Qt::ToolBox-based widget that has some convenience functions to display
        # Roby::Plan objects using the PlanDisplay widget
        class StackedDisplay < Qt::ToolBox
            # Removes all existing displays
            def clear
                while count > 0
                    w = widget(0)
                    if w.display
                        w.display.plan.clear
                    end
                    removeItem(0)
                end
            end

            # Adds a PlanDisplay widget with the given title and parameters
            def push_plan(title, mode, plan, engine, options)
                display = Syskit::GUI::PlanDisplay.new(self)

                display.connect(SIGNAL('updated(QVariant&)')) do |error|
                    emit updated(title, error)
                end
                display.plan = plan
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
end

