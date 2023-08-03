# frozen_string_literal: true

module Syskit
    module GUI
        # Detailed view on a job
        #
        # This is the widget displayed in Syskit IDE when a job is selected. It
        # displays the task chronicle narrowed-down to the tasks involved in the
        # job, as well as exceptions related to this task
        class ExpandedJobStatus < WidgetList
            # @return [Roby::GUI::ExceptionView] display of the exceptions that
            #   are related to this task
            attr_reader :ui_exception_view
            # @return [JobStatusDisplay] the summary widget for the currently
            #   selected job, or nil if no job is selected
            attr_reader :job_status

            def initialize(parent = nil)
                super(parent, auto_resize: false)

                @ui_exception_view = Roby::GUI::ExceptionView.new
                connect(ui_exception_view, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SIGNAL("fileOpenClicked(const QUrl&)"))
                add_widget ui_exception_view
                ui_exception_view.hide
                @job_status = nil
            end

            signals "fileOpenClicked(const QUrl&)"

            # Deselect the current job
            #
            # This updates the chronicle to show all tasks
            def deselect
                disconnect(self, SLOT("exceptionEvent()"))
                @job_status = nil
                update_exceptions([])
            end

            # Select a given job
            #
            # It reduces the displayed information to only the information that
            # involved the selected job
            #
            # @param [JobStatusDisplay] job_status the job status widget that
            #   represents the job to be selected
            def select(job_status)
                disconnect(self, SLOT("exceptionEvent()"))
                @job_status = job_status
                update_exceptions(job_status.exceptions)
                connect(job_status, SIGNAL("exceptionEvent()"), self, SLOT("exceptionEvent()"))
            end

            # Add task and job info
            def add_tasks_info(tasks_info, job_info); end

            # Set the current scheduler state
            def scheduler_state=(state); end

            # Slot used to announce that the exceptions registerd on
            # {#job_status} have changed
            def exceptionEvent
                update_exceptions(job_status.exceptions)
            end
            slots "exceptionEvent()"

            # Update the exception display to display the given exceptions
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
