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

            def initialize(job, batch_manager, job_item_info)
                super(nil)
                @batch_manager = batch_manager
                @job = job
                @exceptions = Array.new
                @ui_summaries_labels = Hash.new
                @job_item_info = job_item_info
                connect @job_item_info, SIGNAL('job_summary_updated()'),
                    self, SLOT('update_notification_summaries()')

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
                attr_reader :max_row_count

                def initialize(*)
                    super
                    @max_row_count = Float::INFINITY
                end

                def show_all_rows
                    self.max_row_count = Float::INFINITY
                end

                def max_row_count=(count)
                    @max_row_count = count
                    update_geometry
                end

                def update_geometry_if_needed
                    count = model.rowCount(root_index)
                    if count == 0
                        hide
                    elsif !@last_row_count || @last_row_count == 0
                        show
                        update_geometry
                    elsif !@last_row_count || count != @last_row_count
                        update_geometry
                    end
                end
                slots 'update_geometry_if_needed()'

                def sizeHint
                    count = [@max_row_count, model.rowCount(root_index)].min
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

                vlayout = Qt::VBoxLayout.new(self)
                vlayout.add_layout header_layout
                @ui_summaries = Qt::VBoxLayout.new
                @ui_summaries.set_contents_margins(0, 0, 0, 0)
                vlayout.add_layout @ui_summaries
                vlayout.add_widget @ui_events

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
                    update_summary('exceptions', "#{exceptions.size} exceptions")
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

            def update_summary(key, text, extended_info: "")
                unless (n = @ui_summaries_labels[key])
                    n = Qt::Label.new(self)
                    @ui_summaries_labels[key] = n
                    @ui_summaries.add_widget(n)
                end
                n.text = "<small>#{text}</small>"
                n.tool_tip = extended_info
                n
            end

            def remove_summary(key)
                if (n = @ui_summaries_labels.delete(key))
                    n.dispose
                    true
                end
            end

            def update_notification_summaries
                agents = @job_item_info.execution_agents
                not_ready = agents.each_key.
                    find_all { |a| !a.ready_event.emitted? }
                if not_ready.size == 0
                    remove_summary('execution_agents_not_ready')
                else
                    all_supported_roles = Set.new
                    full_info = not_ready.map do |agent_task|
                        supported_roles = agents[agent_task]
                        all_supported_roles.merge(supported_roles)
                        "Agent of #{supported_roles.sort.join(", ")}:\n  " +
                            PP.pp(agent_task, '').split("\n").join("\n  ")
                    end.join("\n")

                    update_summary('execution_agents_not_ready',
                        "#{not_ready.size} execution agents are not ready, supporting "\
                        "#{all_supported_roles.size} tasks in this job: "\
                        "#{all_supported_roles.sort.join(", ")}",
                        extended_info: full_info)
                end

                holdoff_messages = @job_item_info.notifications_by_type(
                    JobItemModel::NOTIFICATION_SCHEDULER_HOLDOFF)
                holdoff_count = holdoff_messages.size
                if holdoff_count == 0
                    remove_summary('scheduler_holdoff')
                else
                    full_info = holdoff_messages.values.flatten.join("\n")
                    update_summary('scheduler_holdoff',
                        "#{holdoff_count} tasks cannot be scheduled: "\
                        "#{holdoff_messages.keys.sort.join(", ")}",
                        extended_info: full_info)
                end
            end
            slots 'update_notification_summaries()'

            # Signal emitted when one exception got added at the end of
            # {#exceptions}
            signals 'exceptionEvent()'
        end
    end
end
