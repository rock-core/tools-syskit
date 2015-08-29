require 'syskit/gui/job_state_label'
module Syskit
    module GUI
        class JobStatusDisplay < Qt::Widget
            attr_reader :job

            attr_reader :ui_start
            attr_reader :ui_kill
            attr_reader :ui_state
            attr_reader :ui_exception_view

            def initialize(job, parent = nil)
                @job = job
                super(parent)
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
                ui_state.set_size_policy(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::Minimum)
                @ui_kill = Qt::PushButton.new("Kill", self)
                ui_kill.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)
                @ui_start = Qt::PushButton.new("Restart", self)
                ui_start.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)

                layout = Qt::HBoxLayout.new
                layout.set_contents_margins(0, 0, 0, 0)
                layout.add_widget ui_state
                layout.add_widget ui_start
                layout.add_widget ui_kill

                @ui_exception_view = Roby::GUI::ExceptionView.new(self)
                ui_exception_view.hide
                connect(ui_exception_view, SIGNAL('fileOpenClicked(const QUrl&)'), self, SIGNAL('fileOpenClicked(const QUrl&)'))

                main_layout = Qt::VBoxLayout.new(self)
                main_layout.add_layout layout
                main_layout.add_widget ui_exception_view
            end

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
                    ui_exception_view.push(exception.exception)
                    ui_exception_view.show
                end
            end
        end
    end
end
