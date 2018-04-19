require 'syskit/gui/job_state_label'
module Syskit
    module GUI
        class JobStatusDisplay < Qt::Widget
            attr_reader :job

            attr_reader :ui_job_actions
            attr_reader :ui_start
            attr_reader :ui_restart
            attr_reader :ui_drop
            attr_reader :ui_state
            attr_reader :exceptions
            attr_reader :notifications
            attr_reader :ui_notifications

            def initialize(job, batch_manager, job_item_info)
                super(nil)
                @batch_manager = batch_manager
                @job = job
                @exceptions = Array.new
                @notifications = Hash.new
                @job_item_info = job_item_info

                create_ui
                connect_to_hooks
            end

            INTERMEDIATE_TERMINAL_STATES = [
                Roby::Interface::JOB_SUCCESS.upcase.to_s,
                Roby::Interface::JOB_DROPPED.upcase.to_s,
                Roby::Interface::JOB_FAILED.upcase.to_s,
                Roby::Interface::JOB_PLANNING_FAILED.upcase.to_s
            ]

            def label
                "##{job.job_id} #{job.action_name}"
            end

            class AutoHeightList < Qt::ListView
                def update_geometry_if_needed
                    count = model.rowCount(root_index)
                    if count == 0
                        hide
                    elsif !@last_row_count || @last_row_count == 0
                        show
                    elsif !@last_row_count || count != @last_row_count
                        update_geometry
                    end
                    @last_row_count = count
                end
                slots 'update_geometry_if_needed()'

                def sizeHint
                    count = model.rowCount(root_index)
                    @last_row_count = count
                    Qt::Size.new(sizeHintForColumn(0),
                        count * sizeHintForRow(0))
                end
            end

            def create_ui
                self.focus_policy = Qt::ClickFocus

                header_layout    = Qt::HBoxLayout.new
                @ui_job_actions  = Qt::Widget.new
                header_layout.add_widget(@ui_state   = JobStateLabel.new(name: label))
                header_layout.add_widget(@ui_job_actions)
                header_layout.set_contents_margins(0, 0, 0, 0)

                ui_job_actions_layout = Qt::HBoxLayout.new(@ui_job_actions)
                @actions_buttons = Hash[
                    'Drop'        => Qt::PushButton.new("Drop", self),
                    'Restart'     => Qt::PushButton.new("Restart", self),
                    "Start Again" => Qt::PushButton.new("Start Again", self)
                ]
                ui_job_actions_layout.add_widget(@ui_drop    = @actions_buttons['Drop'])
                ui_job_actions_layout.add_widget(@ui_restart = @actions_buttons['Restart'])
                ui_job_actions_layout.add_widget(@ui_start   = @actions_buttons['Start Again'])
                ui_job_actions_layout.set_contents_margins(0, 0, 0, 0)
                ui_start.hide

                @ui_events            = AutoHeightList.new(self)
                @ui_events.edit_triggers = Qt::AbstractItemView::NoEditTriggers
                @ui_events.vertical_scroll_bar_policy = Qt::ScrollBarAlwaysOff
                @ui_events.horizontal_scroll_bar_policy = Qt::ScrollBarAlwaysOff
                @ui_events.size_policy = Qt::SizePolicy.new(
                    Qt::SizePolicy::Preferred, Qt::SizePolicy::Minimum)
                @ui_events.style_sheet = <<-STYLESHEET
                QListView {
                    font-size: 80%;
                    padding: 3;
                    border: none;
                    background: transparent;
                }
                STYLESHEET
                @job_item_info.display_notifications_on_list(@ui_events)
                connect(@ui_events.model,
                    SIGNAL('rowsInserted(const QModelIndex&, int, int)'),
                    @ui_events, SLOT('update_geometry_if_needed()'))
                connect(@ui_events.model,
                    SIGNAL('rowsRemoved(const QModelIndex&, int, int)'),
                    @ui_events, SLOT('update_geometry_if_needed()'))
                ui_notifications      = Qt::Label.new("", self)

                vlayout = Qt::VBoxLayout.new(self)
                vlayout.add_layout header_layout
                vlayout.add_widget ui_notifications
                vlayout.add_widget @ui_events

                ui_notifications.hide

                if job.state
                    ui_state.update_state(job.state.upcase)
                end
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
            end

            def hide_job_actions
                ui_job_actions.hide
            end

            def mousePressEvent(event)
                emit clicked
                event.accept
            end
            def mouseReleaseEvent(event)
                event.accept
            end
            signals 'clicked()'

            def connect_to_hooks
                ui_drop.connect(SIGNAL('clicked()')) do
                    @batch_manager.drop_job(self)
                    if @actions_immediate
                        @batch_manager.process
                    end
                end
                ui_restart.connect(SIGNAL('clicked()')) do
                    arguments = job.action_arguments.dup
                    arguments.delete(:job_id)
                    if @batch_manager.create_new_job(job.action_name, arguments)
                        @batch_manager.drop_job(self)
                        if @actions_immediate
                            @batch_manager.process
                        end
                    end
                end
                ui_start.connect(SIGNAL('clicked()')) do
                    arguments = job.action_arguments.dup
                    arguments.delete(:job_id)
                    if @batch_manager.create_new_job(job.action_name, arguments)
                        if @actions_immediate
                            @batch_manager.process
                        end
                    end
                end
                job.on_progress do |state|
                    update_state(state)
                end
                job.on_exception do |kind, exception|
                    exceptions << exception.exception
                    notify('exceptions', "#{exceptions.size} exceptions")
                    emit exceptionEvent
                end
            end

            def update_state(state)
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
                    ui_restart.hide
                    ui_start.show
                elsif Roby::Interface.terminal_state?(state)
                    ui_drop.hide
                    ui_restart.hide
                    ui_start.show
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
