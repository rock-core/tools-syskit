# frozen_string_literal: true

require "roby/gui/chronicle_widget"

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
            # @return [Roby::GUI::ChronicleWidget] the chronicle displaying
            #   the task states for the currently selected job, or for all tasks
            #   if there is no currently selected job
            attr_reader :ui_chronicle

            # @return [JobStatusDisplay] the summary widget for the currently
            #   selected job, or nil if no job is selected
            attr_reader :job_status

            def initialize(parent = nil)
                super(parent, auto_resize: false)

                @ui_exception_view = Roby::GUI::ExceptionView.new
                connect(ui_exception_view, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SIGNAL("fileOpenClicked(const QUrl&)"))
                @ui_chronicle = Roby::GUI::ChronicleWidget.new
                ui_chronicle.show_mode = :in_range
                ui_chronicle.reverse_sort = true
                add_widget ui_exception_view
                ui_exception_view.hide
                add_widget ui_chronicle
                @job_status = nil
            end

            signals "fileOpenClicked(const QUrl&)"

            # Deselect the current job
            #
            # This updates the chronicle to show all tasks
            def deselect
                disconnect(self, SLOT("exceptionEvent()"))
                @job_status = nil
                ui_chronicle.clear_tasks_info
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
                ui_chronicle.clear_tasks_info
                update_exceptions(job_status.exceptions)
                connect(job_status, SIGNAL("exceptionEvent()"), self, SLOT("exceptionEvent()"))
            end

            # Add task and job info
            def add_tasks_info(tasks_info, job_info)
                ui_chronicle.add_tasks_info(tasks_info, job_info)
            end

            # Set the current scheduler state
            def scheduler_state=(state)
                ui_chronicle.scheduler_state = state
            end

            # Update the chronicle display
            def update_chronicle
                ui_chronicle.update_current_tasks
                ui_chronicle.update
                children_size_updated
            end

            # Update the current time
            #
            # @param [Integer] cycle_index the index of the current Roby cycle
            # @param [Time] cycle_time the time of the current Roby cycle
            def update_time(cycle_index, cycle_time)
                ui_chronicle.update_current_time(cycle_time)
            end

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
