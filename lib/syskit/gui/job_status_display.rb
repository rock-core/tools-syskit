require 'syskit/gui/job_state_label'
module Syskit
    module GUI
        class JobStatusDisplay < Qt::Widget
            attr_reader :job

            attr_reader :ui_job_actions
            attr_reader :ui_start
            attr_reader :ui_kill
            attr_reader :ui_drop
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
                hide_job_actions
            end

            INTERMEDIATE_TERMINAL_STATES = [
                Roby::Interface::JOB_SUCCESS.upcase.to_s,
                Roby::Interface::JOB_DROPPED.upcase.to_s,
                Roby::Interface::JOB_FAILED.upcase.to_s,
                Roby::Interface::JOB_PLANNING_FAILED.upcase.to_s
            ]

            def create_ui
                @ui_state = JobStateLabel.new name: "##{job.job_id} #{job.action_name}"
                ui_state.update_state(job.state.upcase)

                @ui_job_actions = Qt::Widget.new(self)
                hlayout    = Qt::HBoxLayout.new(ui_job_actions)
                hlayout.add_widget(@ui_kill   = Qt::PushButton.new("Kill", self))
                hlayout.add_widget(@ui_drop   = Qt::PushButton.new("Drop", self))
                hlayout.add_widget(@ui_start  = Qt::PushButton.new("Restart", self))
                hlayout.set_contents_margins(0, 0, 0, 0)

                @ui_notifications = Qt::Label.new("", self)
                ui_notifications.hide

                vlayout = Qt::VBoxLayout.new(self)
                vlayout.add_widget ui_state
                vlayout.add_widget ui_job_actions
                vlayout.add_widget ui_notifications
            end

            def show_job_actions
                ui_job_actions.show
                s = size
                s.height = size_hint.height
                self.size = s
            end

            def hide_job_actions
                ui_job_actions.hide
                s = size
                s.height = size_hint.height
                self.size = s
            end


            def enterEvent(event)
                super
                show_job_actions
            end

            def leaveEvent(event)
                super
                hide_job_actions
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
                ui_drop.connect(SIGNAL('clicked()')) do
                    job.drop
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

                    if state == Roby::Interface::JOB_DROPPED
                        ui_drop.hide
                    elsif Roby::Interface.terminal_state?(state)
                        ui_drop.hide
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
