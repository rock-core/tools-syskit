require 'roby/log/gui/chronicle'
module Syskit
    module GUI
        class ExpandedJobStatus < WidgetList
            attr_reader :ui_exception_view

            attr_reader :ui_chronicle

            def initialize(parent = nil)
                super

                @ui_exception_view = Roby::GUI::ExceptionView.new
                connect(ui_exception_view, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SIGNAL('fileOpenClicked(const QUrl&)'))
                @ui_chronicle = Roby::LogReplay::ChronicleWidget.new
                ui_chronicle.show_mode = :in_range
                ui_chronicle.vertical_scroll_bar_policy = Qt::ScrollBarAlwaysOff
                add_widget ui_exception_view
                ui_exception_view.hide
                add_widget ui_chronicle
                @job_status = nil
            end

            signals 'fileOpenClicked(const QUrl&)'

            def select(job_status)
                disconnect(self, SLOT('exceptionEvent()'))
                @job_status = job_status
                ui_chronicle.clear_tasks_info
                update_exceptions(job_status.exceptions)
                connect(job_status, SIGNAL('exceptionEvent()'), self, SLOT('exceptionEvent()'))
            end

            def add_tasks_info(tasks_info, job_info)
                ui_chronicle.add_tasks_info(tasks_info, job_info)
                children_size_updated
            end

            def update_time(cycle_index, cycle_time)
                ui_chronicle.setCurrentTime(cycle_time)
                children_size_updated
            end

            def exceptionEvent
                update_exceptions(job_status.exceptions)
            end
            slots 'exceptionEvent()'

            def update_exceptions(exceptions)
                ui_exception_view.exceptions = exceptions.dup
                if exceptions.empty?
                    ui_exception_view.hide
                else
                    ui_exception_view.show
                end
                children_size_updated
            end
        end
    end
end

