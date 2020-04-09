# frozen_string_literal: true

require "syskit/gui/job_state_label"
module Syskit
    module GUI
        class JobStatusDisplay < Qt::Widget
            attr_reader :job

            attr_reader :ui_job_actions
            attr_reader :ui_start
            attr_reader :ui_restart
            attr_reader :ui_drop
            attr_reader :ui_clear
            attr_reader :ui_state
            attr_reader :exceptions
            attr_reader :notifications
            attr_reader :ui_notifications

            attr_predicate :show_actions?, true

            def initialize(job, batch_manager)
                super(nil)
                @batch_manager = batch_manager
                @job = job
                @exceptions = []
                @notifications = {}
                @show_actions = true

                create_ui
                connect_to_hooks
                hide_job_actions
            end

            INTERMEDIATE_TERMINAL_STATES = [
                Roby::Interface::JOB_SUCCESS.upcase.to_s,
                Roby::Interface::JOB_DROPPED.upcase.to_s,
                Roby::Interface::JOB_FAILED.upcase.to_s,
                Roby::Interface::JOB_PLANNING_FAILED.upcase.to_s
            ].freeze

            def label
                "##{job.job_id} #{job.action_name}"
            end

            def create_ui
                self.focus_policy = Qt::ClickFocus
                @ui_state = JobStateLabel.new name: label
                if job.state
                    ui_state.update_state(job.state.upcase)
                end

                @ui_job_actions = Qt::Widget.new(self)
                hlayout = Qt::HBoxLayout.new(ui_job_actions)
                @actions_buttons = Hash[
                    "Drop" => Qt::PushButton.new("Drop", self),
                    "Restart" => Qt::PushButton.new("Restart", self),
                    "Start Again" => Qt::PushButton.new("Start Again", self),
                    "Clear" => Qt::PushButton.new("Clear", self)
                ]
                hlayout.add_widget(@ui_drop = @actions_buttons["Drop"])
                hlayout.add_widget(@ui_restart = @actions_buttons["Restart"])
                hlayout.add_widget(@ui_start   = @actions_buttons["Start Again"])
                hlayout.add_widget(@ui_clear   = @actions_buttons["Clear"])

                ui_start.hide
                ui_clear.hide
                hlayout.set_contents_margins(0, 0, 0, 0)

                @ui_notifications = Qt::Label.new("", self)
                ui_notifications.hide

                vlayout = Qt::VBoxLayout.new(self)
                vlayout.add_widget ui_state
                vlayout.add_widget ui_job_actions
                vlayout.add_widget ui_notifications
            end

            def keyPressEvent(event)
                make_actions_immediate(event.key == Qt::Key_Control)
                super
            end

            def keyReleaseEvent(event)
                make_actions_immediate(false)
                super
            end

            def make_actions_immediate(enable)
                @actions_immediate = enable
                if enable
                    @actions_buttons.each do |text, btn|
                        btn.text = "#{text} Now"
                    end
                else
                    @actions_buttons.each do |text, btn|
                        btn.text = text
                    end
                end
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
                if show_actions?
                    show_job_actions
                    self.focus = Qt::OtherFocusReason
                end
            end

            def leaveEvent(event)
                super
                if show_actions?
                    hide_job_actions
                end
            end

            def mousePressEvent(event)
                emit clicked
                event.accept
            end

            def mouseReleaseEvent(event)
                event.accept
            end
            signals "clicked()"

            def connect_to_hooks
                ui_drop.connect(SIGNAL("clicked()")) do
                    @batch_manager.drop_job(self)
                    if @actions_immediate
                        @batch_manager.process
                    end
                end
                ui_restart.connect(SIGNAL("clicked()")) do
                    arguments = job.action_arguments.dup
                    arguments.delete(:job_id)
                    if @batch_manager.create_new_job(job.action_name, arguments)
                        @batch_manager.drop_job(self)
                        if @actions_immediate
                            @batch_manager.process
                        end
                    end
                end
                ui_start.connect(SIGNAL("clicked()")) do
                    arguments = job.action_arguments.dup
                    arguments.delete(:job_id)
                    if @batch_manager.create_new_job(job.action_name, arguments)
                        if @actions_immediate
                            @batch_manager.process
                        end
                    end
                end
                ui_clear.connect(SIGNAL("clicked()")) do
                    unless job.active?
                        job.stop
                        emit clearJob
                        true
                    end
                end
                job.on_progress do |state|
                    update_state(state)
                end
                job.on_exception do |kind, exception|
                    exceptions << exception.exception
                    notify("exceptions", "#{exceptions.size} exceptions")
                    emit exceptionEvent
                end
            end

            def update_state(state)
                if INTERMEDIATE_TERMINAL_STATES.include?(ui_state.current_state)
                    ui_state.update_state(
                        "#{ui_state.current_state},
                            #{state.upcase}",
                        color: ui_state.current_color
                    )
                else
                    ui_state.update_state(state.upcase)
                end

                if state == Roby::Interface::JOB_DROPPED
                    ui_drop.hide
                    ui_restart.hide
                    ui_start.show
                    ui_clear.show
                elsif Roby::Interface.terminal_state?(state)
                    ui_drop.hide
                    ui_restart.hide
                    ui_start.show
                    ui_clear.show
                end
            end

            def notify(key, text)
                notifications[key] = text
                ui_notifications.show
                ui_notifications.text = "<small>#{notifications.values.join(', ')}</small>"
            end

            # Signal emitted when one exception got added at the end of
            # {#exceptions}
            signals "exceptionEvent()"
            signals "clearJob()"
        end
    end
end
