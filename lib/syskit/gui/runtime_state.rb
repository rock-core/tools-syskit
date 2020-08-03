# frozen_string_literal: true

require "syskit"
require "roby/interface/async"
require "roby/interface/async/log"
require "syskit/gui/logging_configuration"
require "syskit/gui/job_status_display"
require "syskit/gui/widget_list"
require "syskit/gui/expanded_job_status"
require "syskit/gui/global_state_label"
require "syskit/gui/app_start_dialog"
require "syskit/gui/batch_manager"

module Syskit
    module GUI
        # UI that displays and allows to control jobs
        class RuntimeState < Qt::Widget
            include Roby::Hooks
            include Roby::Hooks::InstanceHooks

            # @return [Roby::Interface::Async::Interface] the underlying syskit
            #   interface
            attr_reader :syskit
            # An async object to access the log stream
            attr_reader :syskit_log_stream

            # The toplevel layout
            attr_reader :main_layout
            # The layout used to organize the widgets to create new jobs
            attr_reader :new_job_layout
            # The [WidgetList] widget in which we display the
            # summary of job status
            attr_reader :job_status_list
            # The [ExpandedJobStatus] widget in which we display expanded job
            # information
            attr_reader :job_expanded_status
            # The combo box used to create new jobs
            attr_reader :action_combo
            # The job that is currently selected
            attr_reader :current_job
            # The connection state, which gives access to the global Syskit
            # state
            attr_reader :connection_state

            # All known tasks
            attr_reader :all_tasks
            # Job information for tasks in the rebuilt plan
            attr_reader :all_job_info

            # The name service which allows us to resolve Rock task contexts
            attr_reader :name_service
            # A task inspector widget we use to display the task states
            attr_reader :ui_task_inspector
            # A logging configuration widget we use to manage logging
            attr_reader :ui_logging_configuration
            # The list of task names of the task currently displayed by the task
            # inspector
            attr_reader :current_orocos_tasks

            # Returns a list of actions that can be performed on the Roby
            # instance
            #
            # @return [Array<Qt::Action>]
            attr_reader :global_actions

            # The current connection state
            attr_reader :current_state

            # Checkboxes to select widgets options
            attr_reader :ui_hide_loggers
            attr_reader :ui_show_expanded_job

            define_hooks :on_connection_state_changed
            define_hooks :on_progress

            class ActionListDelegate < Qt::StyledItemDelegate
                OUTER_MARGIN = 5
                INTERLINE    = 3
                def sizeHint(option, index)
                    fm = option.font_metrics
                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ""
                    Qt::Size.new(
                        [fm.width(main), fm.width(doc)].max + 2 * OUTER_MARGIN,
                        fm.height * 2 + OUTER_MARGIN * 2 + INTERLINE
                    )
                end

                def paint(painter, option, index)
                    painter.save

                    if (option.state & Qt::Style::State_Selected) != 0
                        painter.fill_rect(option.rect, option.palette.highlight)
                        painter.brush = option.palette.highlighted_text
                    end

                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ""
                    text_bounds = Qt::Rect.new

                    fm = option.font_metrics
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, main, text_bounds
                    )

                    font = painter.font
                    font.italic = true
                    painter.font = font
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, doc, text_bounds
                    )
                ensure
                    painter.restore
                end
            end

            # @param [Roby::Interface::Async::Interface] syskit the underlying
            #   syskit interface
            # @param [Integer] poll_period how often should the syskit interface
            #   be polled (milliseconds). Set to nil if the polling is already
            #   done externally
            def initialize(parent: nil, robot_name: "default",
                syskit: Roby::Interface::Async::Interface.new, poll_period: 50)

                super(parent)

                @syskit = syskit
                @robot_name = robot_name
                reset

                @syskit_poll = Qt::Timer.new
                @syskit_poll_period = poll_period
                connect syskit_poll, SIGNAL("timeout()"),
                        self, SLOT("poll_syskit_interface()")

                if poll_period
                    @syskit_poll.start(poll_period)
                end

                create_ui

                @global_actions = {}
                action = global_actions[:start] = Qt::Action.new("Start", self)
                @starting_monitor = Qt::Timer.new
                connect @starting_monitor, SIGNAL("timeout()"),
                        self, SLOT("monitor_syskit_startup()")
                connect action, SIGNAL("triggered()") do
                    app_start(robot_name: @robot_name, port: syskit.remote_port)
                end
                action = global_actions[:restart] = Qt::Action.new("Restart", self)
                connect action, SIGNAL("triggered()") do
                    app_restart
                end
                action = global_actions[:quit] = Qt::Action.new("Quit", self)
                connect action, SIGNAL("triggered()") do
                    app_quit
                end

                @current_job = nil
                @current_orocos_tasks = Set.new
                @all_tasks = Set.new
                @known_loggers = nil
                @all_job_info = {}
                syskit.on_ui_event do |event_name, *args|
                    if w = @ui_event_widgets[event_name]
                        w.show
                        w.update(*args)
                    else
                        puts "don't know what to do with UI event #{event_name}, known events: #{@ui_event_widgets}"
                    end
                end
                on_connection_state_changed do |state|
                    @current_state = state
                    connection_state.update_state state
                end
                syskit.on_reachable do
                    @syskit_commands = syskit.client.syskit
                    update_log_server_connection(syskit.log_server_port)
                    @job_status_list.each_widget do |w|
                        w.show_actions = true
                    end
                    action_combo.clear
                    action_combo.enabled = true
                    syskit.actions.sort_by(&:name).each do |action|
                        next if action.advanced?

                        action_combo.add_item(action.name, Qt::Variant.new(action.doc))
                    end
                    ui_logging_configuration.refresh
                    global_actions[:start].visible = false
                    global_actions[:restart].visible = true
                    global_actions[:quit].visible = true
                    @starting_monitor.stop
                    run_hook :on_connection_state_changed, "CONNECTED"
                end
                syskit.on_unreachable do
                    @syskit_commands = nil
                    @job_status_list.each_widget do |w|
                        w.show_actions = false
                    end
                    @ui_event_widgets.each_value(&:hide)
                    action_combo.enabled = false
                    @batch_manager.cancel
                    if remote_name == "localhost"
                        global_actions[:start].visible = true
                    end
                    ui_logging_configuration.refresh
                    global_actions[:restart].visible = false
                    global_actions[:quit].visible = false
                    if @current_state != "RESTARTING"
                        run_hook :on_connection_state_changed, "UNREACHABLE"
                    end
                end
                syskit.on_job do |job|
                    job.start
                    monitor_job(job)
                end
            end

            def monitor_syskit_startup
                return unless @syskit_pid

                begin
                    _pid, has_quit = Process.waitpid2(
                        @syskit_pid, Process::WNOHANG
                    )
                rescue Errno::ECHILD
                    has_quit = true
                end

                if has_quit
                    @syskit_pid = nil
                    run_hook :on_connection_state_changed, "UNREACHABLE"
                    @starting_monitor.stop
                end
            end
            slots "monitor_syskit_startup()"

            def reset
                Orocos.initialize
                @logger_m = nil
                orocos_corba_nameservice = Orocos::CORBA::NameService.new(syskit.remote_name)
                @name_service = Orocos::Async::NameService.new(orocos_corba_nameservice)
            end

            def update_log_server_connection(port)
                if syskit_log_stream && (syskit_log_stream.port == port)
                    return
                elsif syskit_log_stream
                    syskit_log_stream.close
                end

                @syskit_log_stream = Roby::Interface::Async::Log.new(syskit.remote_name, port: port)
                syskit_log_stream.on_reachable do
                    deselect_job
                end
                syskit_log_stream.on_init_progress do |rx, expected|
                    run_hook :on_progress, format("loading %02i", Float(rx) / expected * 100)
                end
                syskit_log_stream.on_update do |cycle_index, cycle_time|
                    if syskit_log_stream.init_done?
                        time_s = cycle_time.strftime("%H:%M:%S.%3N").to_s
                        run_hook :on_progress, format("@%i %s", cycle_index, time_s)

                        job_expanded_status.update_time(cycle_index, cycle_time)
                        update_tasks_info
                        job_expanded_status.add_tasks_info(all_tasks, all_job_info)
                        job_expanded_status.scheduler_state = syskit_log_stream.scheduler_state
                        job_expanded_status.update_chronicle unless hide_expanded_jobs?
                    end
                    syskit_log_stream.clear_integrated
                end
            end

            def hide_loggers?
                !@ui_hide_loggers.checked?
            end

            def hide_expanded_jobs?
                !@ui_show_expanded_job.checked
            end

            def remote_name
                syskit.remote_name
            end

            def app_start(robot_name: "default", port: nil)
                robot_name, start_controller = AppStartDialog.exec(
                    Roby.app.robots.names, self, default_robot_name: robot_name
                )
                return unless robot_name

                extra_args = []
                extra_args << "-r" << robot_name unless robot_name.empty?
                extra_args << "-c" if start_controller
                extra_args << "--port=#{port}" if port
                extra_args.concat(
                    Roby.app.argv_set.flat_map { |arg| ["--set", arg] }
                )
                @syskit_pid =
                    Kernel.spawn Gem.ruby, "-S", "syskit", "run", "--wait-shell-connection",
                                 *extra_args,
                                 pgroup: true
                @starting_monitor.start(100)
                run_hook :on_connection_state_changed, "STARTING"
            end

            def app_quit
                syskit.quit
            end

            def app_restart
                run_hook :on_connection_state_changed, "RESTARTING"
                if @syskit_pid
                    @starting_monitor.start(100)
                end
                syskit.restart
            end

            def logger_task?(t)
                return if @logger_m == false

                @logger_m ||= Syskit::TaskContext
                              .find_model_from_orogen_name("logger::Logger") || false
                t.kind_of?(@logger_m)
            end

            def update_tasks_info
                if current_job
                    job_task = syskit_log_stream.plan.find_tasks(Roby::Interface::Job)
                                                .with_arguments(job_id: current_job.job_id)
                                                .first
                    return unless job_task

                    placeholder_task = job_task.planned_task
                    return unless placeholder_task

                    dependency = placeholder_task.relation_graph_for(Roby::TaskStructure::Dependency)
                    tasks = dependency.enum_for(:depth_first_visit, placeholder_task).to_a
                    tasks << job_task
                else
                    tasks = syskit_log_stream.plan.tasks
                end

                if hide_loggers?
                    unless @known_loggers
                        @known_loggers = Set.new
                        all_tasks.delete_if do |t|
                            @known_loggers << t if logger_task?(t)
                        end
                    end

                    tasks = tasks.find_all do |t|
                        if all_tasks.include?(t)
                            true
                        elsif @known_loggers.include?(t)
                            false
                        elsif logger_task?(t)
                            @known_loggers << t
                            false
                        else true
                        end
                    end
                end
                all_tasks.merge(tasks)
                tasks.each do |job|
                    if job.kind_of?(Roby::Interface::Job)
                        if placeholder_task = job.planned_task
                            all_job_info[placeholder_task] = job
                        end
                    end
                end
                update_orocos_tasks
            end

            def update_orocos_tasks
                candidate_tasks = all_tasks
                                  .find_all { |t| t.kind_of?(Syskit::TaskContext) }
                orocos_tasks = candidate_tasks.map { |t| t.arguments[:orocos_name] }.compact.to_set
                removed = current_orocos_tasks - orocos_tasks
                new     = orocos_tasks - current_orocos_tasks
                removed.each do |task_name|
                    ui_task_inspector.remove_task(task_name)
                end
                new.each do |task_name|
                    ui_task_inspector.add_task(name_service.proxy(task_name))
                end
                @current_orocos_tasks = orocos_tasks
            end

            EventWidget = Struct.new :name, :widget, :hook do
                def show
                    widget.show
                end

                def hide
                    widget.hide
                end

                def update(*args)
                    hook.call(*args)
                end
            end

            def create_ui
                job_summary = Qt::Widget.new
                job_summary_layout = Qt::VBoxLayout.new(job_summary)
                job_summary_layout.add_layout(@new_job_layout = create_ui_new_job)

                @connection_state = GlobalStateLabel.new(name: remote_name)
                on_progress do |message|
                    state = connection_state.current_state.to_s
                    connection_state.update_text(format("%s - %s", state, message))
                end
                job_summary_layout.add_widget(connection_state, 0)

                @clear_button = Qt::PushButton.new("Clear Finished Jobs")
                job_summary_layout.add_widget(@clear_button)
                @clear_button.connect(SIGNAL(:clicked)) do
                    @job_status_list.clear_widgets do |w|
                        unless w.job.active?
                            w.job.stop
                            true
                        end
                    end
                end

                @batch_manager = BatchManager.new(@syskit, self)
                job_summary_layout.add_widget(@batch_manager)
                @batch_manager.connect(SIGNAL("active(bool)")) do |active|
                    if active then @batch_manager.show
                    else @batch_manager.hide
                    end
                end
                @batch_manager.hide
                connection_state.connect(SIGNAL("clicked(QPoint)")) do
                    deselect_job
                end

                @job_status_list = WidgetList.new(self)
                @job_status_list.size_constraint = Qt::Layout::SetFixedSize
                job_status_scroll = Qt::ScrollArea.new
                job_status_scroll.widget = @job_status_list
                job_summary_layout.add_widget(job_status_scroll, 1)
                @main_layout = Qt::VBoxLayout.new(self)

                @ui_event_widgets = create_ui_event_widgets
                @ui_event_widgets.each_value do |w|
                    @main_layout.add_widget(w.widget)
                end

                splitter = Qt::Splitter.new
                splitter.add_widget job_summary
                splitter.add_widget(@job_expanded_status = ExpandedJobStatus.new)
                connect(@job_expanded_status, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SIGNAL("fileOpenClicked(const QUrl&)"))

                task_inspector_widget = Qt::Widget.new
                task_inspector_layout = Qt::VBoxLayout.new(task_inspector_widget)
                task_inspector_checkboxes_layout = Qt::HBoxLayout.new
                task_inspector_checkboxes_layout.add_widget(
                    @ui_show_expanded_job = Qt::CheckBox.new("Show details")
                )
                task_inspector_checkboxes_layout.add_widget(
                    @ui_hide_loggers = Qt::CheckBox.new("Show loggers")
                )
                task_inspector_checkboxes_layout.add_stretch
                task_inspector_layout.add_layout(task_inspector_checkboxes_layout)
                task_inspector_layout.add_widget(
                    @ui_task_inspector = Vizkit.default_loader.TaskInspector
                )
                @ui_hide_loggers.checked = false
                @ui_hide_loggers.connect SIGNAL("toggled(bool)") do |checked|
                    @known_loggers = nil
                    update_tasks_info
                end
                @ui_show_expanded_job.checked = true
                @ui_show_expanded_job.connect SIGNAL("toggled(bool)") do |checked|
                    job_expanded_status.visible = checked
                end

                @ui_logging_configuration = LoggingConfiguration.new(syskit)

                management_tab_widget = Qt::TabWidget.new(self)
                management_tab_widget.addTab(task_inspector_widget, "Tasks")
                management_tab_widget.addTab(ui_logging_configuration, "Logging")

                splitter.add_widget(management_tab_widget)
                job_expanded_status.set_size_policy(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::MinimumExpanding)
                @main_layout.add_widget splitter, 1
                w = splitter.size.width
                splitter.sizes = [Integer(w * 0.25), Integer(w * 0.50), Integer(w * 0.25)]
                nil
            end

            def create_ui_event_frame
                frame = Qt::Frame.new(self)
                frame.frame_shape = Qt::Frame::StyledPanel
                frame.setStyleSheet("QFrame { background-color: rgb(205,235,255); border-radius: 2px; }")
                frame
            end

            def create_ui_event_button(text)
                button = Qt::PushButton.new(text)
                button.flat = true
                button
            end

            def create_ui_event_orogen_config_changed
                syskit_orogen_config_changed = create_ui_event_frame
                layout = Qt::HBoxLayout.new(syskit_orogen_config_changed)
                layout.add_widget(Qt::Label.new("oroGen configuration files changes on disk"), 1)
                layout.add_widget(reload = create_ui_event_button("Reload"))
                layout.add_widget(close  = create_ui_event_button("Close"))
                reload.connect(SIGNAL("clicked()")) do
                    @syskit_commands.async_reload_config do
                        syskit_orogen_config_changed.hide
                    end
                end
                close.connect(SIGNAL("clicked()")) do
                    syskit_orogen_config_changed.hide
                end
                EventWidget.new(
                    "syskit_orogen_config_changed",
                    syskit_orogen_config_changed, -> {}
                )
            end

            def create_ui_event_orogen_config_reloaded
                syskit_orogen_config_reloaded = create_ui_event_frame
                layout = Qt::HBoxLayout.new(syskit_orogen_config_reloaded)
                layout.add_widget(label = Qt::Label.new, 1)
                layout.add_widget(apply = create_ui_event_button("Reconfigure"))
                layout.add_widget(close = create_ui_event_button("Close"))
                apply.connect(SIGNAL("clicked()")) do
                    @syskit_commands.async_redeploy do
                        syskit_orogen_config_reloaded.hide
                    end
                end
                close.connect(SIGNAL("clicked()")) do
                    syskit_orogen_config_reloaded.hide
                end
                syskit_orogen_config_reloaded_hook = lambda do |changed_tasks, changed_tasks_running|
                    if changed_tasks.empty?
                        label.text = "oroGen configuration updated"
                        apply.hide
                    elsif changed_tasks_running.empty?
                        label.text = "oroGen configuration modifications applied to #{changed_tasks.size} configured but not running tasks"
                        apply.hide
                    else
                        label.text = "oroGen configuration modifications applied to #{changed_tasks_running.size} running tasks and #{changed_tasks.size - changed_tasks_running.size} configured but not running tasks"
                        apply.show
                    end
                end
                EventWidget.new("syskit_orogen_config_reloaded",
                                syskit_orogen_config_reloaded,
                                syskit_orogen_config_reloaded_hook)
            end

            def create_ui_event_widgets
                widgets = [
                    create_ui_event_orogen_config_reloaded,
                    create_ui_event_orogen_config_changed
                ]
                ui_event_widgets = {}
                widgets.each do |w|
                    w.hide
                    ui_event_widgets[w.name] = w
                end
                ui_event_widgets
            end

            def create_ui_new_job
                new_job_layout = Qt::HBoxLayout.new
                label = Qt::Label.new("New Job", self)
                label.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)
                @action_combo = Qt::ComboBox.new(self)
                action_combo.enabled = false
                action_combo.item_delegate = ActionListDelegate.new(self)
                new_job_layout.add_widget label
                new_job_layout.add_widget action_combo, 1
                action_combo.connect(SIGNAL("activated(QString)")) do |action_name|
                    @batch_manager.create_new_job(action_name)
                end
                new_job_layout
            end

            attr_reader :syskit_poll

            # @api private
            #
            # Sets up polling on a given syskit interface
            def poll_syskit_interface
                syskit.poll
                if syskit_log_stream
                    if syskit_log_stream.poll(max: 0.05) == Roby::Interface::Async::Log::STATE_PENDING_DATA
                        syskit_poll.interval = 0
                    else
                        syskit_poll.interval = @syskit_poll_period
                    end
                end
            end
            slots "poll_syskit_interface()"

            # @api private
            #
            # Create the UI elements for the given job
            #
            # @param [Roby::Interface::Async::JobMonitor] job
            def monitor_job(job)
                job_status = JobStatusDisplay.new(job, @batch_manager)
                job_status_list.add_widget job_status
                job_status.connect(SIGNAL("clicked()")) do
                    select_job(job_status)
                end
                job_status.connect(SIGNAL("clearJob()")) do
                    job_status_list.clear_widgets do |job|
                        job == job_status
                    end
                end
            end

            def deselect_job
                @current_job = nil
                job_expanded_status.deselect
                all_tasks.clear
                @known_loggers = nil
                all_job_info.clear
                if syskit_log_stream
                    update_tasks_info
                end
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            def select_job(job_status)
                @current_job = job_status.job
                all_tasks.clear
                @known_loggers = nil
                all_job_info.clear
                update_tasks_info
                job_expanded_status.select(job_status)
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            def restore_from_settings(settings)
                %w{ui_hide_loggers ui_show_expanded_job}.each do |checkbox_name|
                    default = Qt::Variant.new(send(checkbox_name).checked)
                    send(checkbox_name).checked = settings.value(checkbox_name, default).to_bool
                end
            end

            def save_to_settings(settings)
                %w(ui_hide_loggers ui_show_expanded_job).each do |checkbox_name|
                    settings.set_value checkbox_name, Qt::Variant.new(send(checkbox_name).checked)
                end
            end

            signals "fileOpenClicked(const QUrl&)"
        end
    end
end
