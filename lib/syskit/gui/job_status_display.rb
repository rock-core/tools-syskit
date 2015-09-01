require 'syskit/gui/job_state_label'
module Syskit
    module GUI
        class JobStatusDisplay < Qt::Widget
            attr_reader :job

            attr_reader :ui_start
            attr_reader :ui_kill
            attr_reader :ui_state
            attr_reader :exceptions
            attr_reader :notifications
            attr_reader :ui_notifications

            def initialize(job, parent = nil)
                super(parent)
                @job = job
                @exceptions = Array.new
                @notifications = Hash.new

                create_ui
                connect_to_hooks
            end

            INTERMEDIATE_TERMINAL_STATES = [
                Roby::Interface::JOB_SUCCESS.upcase.to_s,
                Roby::Interface::JOB_FAILED.upcase.to_s,
                Roby::Interface::JOB_PLANNING_FAILED.upcase.to_s
            ]

            def create_ui
                @ui_state = JobStateLabel.new name: "##{job.job_id} #{job.action_name}"
                ui_state.update_state(job.state.upcase)
                ui_state.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::MinimumExpanding)
                @ui_kill = Qt::PushButton.new("Kill", self)
                ui_kill.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)
                @ui_start = Qt::PushButton.new("Restart", self)
                ui_start.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)

                vlayout = Qt::VBoxLayout.new(self)
                hlayout = Qt::HBoxLayout.new
                vlayout.add_layout hlayout

                hlayout.set_contents_margins(0, 0, 0, 0)
                hlayout.add_widget ui_state, 1
                hlayout.add_widget ui_start
                hlayout.add_widget ui_kill

                @ui_notifications = Qt::Label.new("", self)
                ui_notifications.hide
                vlayout.add_widget(ui_notifications)
            end

            def mousePressEvent(event)
                emit clicked
                event.accept
            end
            def mouseReleaseEvent(event)
                event.accept
            end
            signals 'clicked()'

            signals 'fileOpenClicked(const QUrl&)'

            def connect_to_hooks
                ui_start.connect(SIGNAL('clicked()')) do
                    job.restart
                end
                ui_kill.connect(SIGNAL('clicked()')) do
                    job.kill
                end
                job.on_progress do |state|
                    if INTERMEDIATE_TERMINAL_STATES.include?(ui_state.current_state)
                        ui_state.update_state(
                            "#{ui_state.current_state},
                            #{state.upcase}",
                            color: ui_state.current_color)
                    else
                        ui_state.update_state(state.upcase)
                    end

                    if Roby::Interface.terminal_state?(state)
                        ui_kill.hide
                        ui_start.text = "Start Again"
                    end
                end
                job.on_exception do |kind, exception|
                    exceptions << exception.exception
                    notify('exceptions', "#{exceptions.size} exceptions")
                    emit exceptionEvent
                end
            end

            def notify(key, text)
                notifications[key] = text
                ui_notifications.show
                ui_notifications.text = "<small>#{notifications.values.join(", ")}</small>"
            end

            # Signal emitted when one exception got added at the end of
            # {#exceptions}
            signals 'exceptionEvent()'
        end
    end
end
