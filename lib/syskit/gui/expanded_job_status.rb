module Syskit
    module GUI
        class ExpandedJobStatus < WidgetList
            attr_reader :ui_exception_view

            def initialize(parent = nil)
                super

                @ui_exception_view = Roby::GUI::ExceptionView.new
                connect(ui_exception_view, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SIGNAL('fileOpenClicked(const QUrl&)'))
                add_widget ui_exception_view
                @job_status = nil
            end

            signals 'fileOpenClicked(const QUrl&)'

            def update(job_status)
                disconnect(self, SLOT('exceptionEvent()'))
                @job_status = job_status
                update_exceptions(job_status.exceptions)
                connect(job_status, SIGNAL('exceptionEvent()'), self, SLOT('exceptionEvent()'))
            end

            def exceptionEvent
                update_exceptions(job_status.exceptions)
            end
            slots 'exceptionEvent()'

            def update_exceptions(exceptions)
                ui_exception_view.exceptions = exceptions.dup
                s = widget.size
                s.height = ui_exception_view.size_hint.height
                widget.size = s
                if exceptions.empty?
                    ui_exception_view.hide
                else
                    ui_exception_view.show
                end
            end
        end
    end
end

