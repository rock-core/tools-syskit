require 'orocos/roby/gui/stacked_display'

module Ui
    # Widget used by rock-roby instanciate as the main widget
    class InstanciatedNetworkDisplay < Qt::Widget
        attr_reader :plan_display
        attr_reader :error_list
        attr_reader :splitter

        def initialize(parent = nil)
            super

            layout = Qt::HBoxLayout.new(self)
            @splitter = Qt::Splitter.new(Qt::Vertical, self)
            layout.add_widget(splitter)

            splitter.add_widget(@error_list = Qt::TreeWidget.new(splitter))
            error_list.set_size_policy(Qt::SizePolicy::Preferred, Qt::SizePolicy::Preferred)
            splitter.add_widget(@plan_display = Ui::StackedDisplay.new(splitter))
            plan_display.set_size_policy(Qt::SizePolicy::Preferred, Qt::SizePolicy::MinimumExpanding)
            Qt::Object.connect(plan_display, SIGNAL('updated(QString,QVariant&)'), self, SLOT('planDisplayUpdated(QString,QVariant&)'))
            error_list.header_label = "Errors"

            error_list.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, col|
                exception = item.data(0, Qt::UserRole)
                if exception.valid?
                    exception = exception.value

                    if exception.respond_to?(:task)
                        task = exception.task
                        # Get the task in the active display
                        current_display = plan_display.currentWidget
                        current_display_task = plan_display.task_mappings[current_display][task]
                        current_display.options.delete(:highlights)
                        current_display.options[:highlights] = [current_display_task]
                        current_display.display
                        current_display.ensure_visible(current_display_task)
                    end
                end
            end
        end

        def planDisplayUpdated(title, error)
            if @current_display_error
                @current_display_error.dispose
            end
            if error.valid?
                error = error.value
                @current_display_error = add_error(error, title)
            end
        end
        slots 'planDisplayUpdated(QString,QVariant&)'

        def clear
            plan_display.clear
            if @current_display_error
                @current_display_error.dispose
            end
            error_list.clear
        end


        def add_error(exception, title = nil)
            exception_text = Roby.format_exception(exception)
            if title
                exception_text[0] = "in #{title}: #{exception_text[0]}"
            end
            backtrace_text = Roby.format_exception(Roby::BacktraceFormatter.new(exception))

            item = Qt::TreeWidgetItem.new(error_list, [])
            error_list.setItemWidget(item, 0, Qt::Label.new(exception_text.join("\n")))
            backtrace_item = Qt::TreeWidgetItem.new(item, [])
            error_list.setItemWidget(backtrace_item, 0, Qt::Label.new(backtrace_text.join("\n")))

            # prevent 'unresolved constructor call Qt::Variant (ArgumentError)' 
            # for older Qt versions
            if ! Qt.version < "4.7"
                item.set_data(0, Qt::UserRole, Qt::Variant.fromValue(exception))
            end

            item
        end

        def display_plan(plan, engine)
            clear
            plan_display.push_plan('Task Dependency Hierarchy', 'hierarchy',
                  plan, engine, Hash.new)
            plan_display.push_plan('Dataflow', 'dataflow',
                  plan, engine, Hash.new)
        end
    end
end
