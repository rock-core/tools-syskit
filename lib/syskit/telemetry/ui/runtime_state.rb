# frozen_string_literal: true

require "Qt"
require "qtwebkit"
require "vizkit"
require "syskit"
require "orocos/async"
require "metaruby/gui/exception_view"
require "roby/interface/v2/async"
require "roby/gui/exception_view"
require "syskit/telemetry/ui/logging_configuration"
require "syskit/telemetry/ui/job_status_display"
require "syskit/telemetry/ui/widget_list"
require "syskit/telemetry/ui/expanded_job_status"
require "syskit/telemetry/ui/global_state_label"
require "syskit/telemetry/ui/app_start_dialog"
require "syskit/telemetry/ui/batch_manager"
require "syskit/telemetry/async"
require "syskit/interface/v2"

# Monkey patching from Vizkit
Syskit::Telemetry::Async::OutputPort.include Orocos::QtOrocos
Syskit::Telemetry::Async::OutputPortSubfield.include Orocos::QtOrocos

module Syskit
    module Telemetry
        module UI
            # UI that displays and allows to control jobs
            class RuntimeState < Qt::Widget
                include Roby::Hooks
                include Roby::Hooks::InstanceHooks

                # @return [Roby::Interface::V2::Async::Interface] the underlying syskit
                #   interface
                attr_reader :syskit

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

                # The name service which allows us to resolve Rock task contexts
                attr_reader :name_service
                # A task inspector widget we use to display the task states
                attr_reader :ui_task_inspector
                # A logging configuration widget we use to manage logging
                attr_reader :ui_logging_configuration

                # Returns a list of actions that can be performed on the Roby
                # instance
                #
                # @return [Array<Qt::Action>]
                attr_reader :global_actions

                # The current connection state
                attr_reader :current_state

                # Checkboxes to select widgets options
                attr_reader :ui_hide_loggers
                attr_reader :ui_show_expanded_job, :syskit_poll

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
                            [fm.width(main), fm.width(doc)].max + (2 * OUTER_MARGIN),
                            (fm.height * 2) + (OUTER_MARGIN * 2) + INTERLINE
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
                            Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - (2 * OUTER_MARGIN), fm.height),
                            Qt::AlignLeft, main, text_bounds
                        )

                        font = painter.font
                        font.italic = true
                        painter.font = font
                        painter.draw_text(
                            Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - (2 * OUTER_MARGIN), fm.height),
                            Qt::AlignLeft, doc, text_bounds
                        )
                    ensure
                        painter.restore
                    end
                end

                # @param [Roby::Interface::V2::Async::Interface] syskit the underlying
                #   syskit interface
                # @param [Integer] poll_period how often should the syskit interface
                #   be polled (milliseconds). Set to nil if the polling is already
                #   done externally
                def initialize(parent: nil,
                    syskit: Roby::Interface::V2::Async::Interface.new, poll_period: 50)

                    super(parent)

                    @syskit = syskit
                    @syskit_run_arguments =
                        SyskitRunArguments.new(robot: "default", set: [])
                    reset

                    @syskit_poll = Qt::Timer.new
                    @syskit_poll_period = poll_period
                    connect syskit_poll, SIGNAL("timeout()"),
                            self, SLOT("poll_syskit_interface()")

                    @syskit_poll.start(poll_period) if poll_period
                    @global_actions = create_app_start_actions

                    create_ui

                    @current_job = nil
                    @current_job_tasks = []
                    @current_tasks = []

                    syskit.on_ui_event do |event_name, *args|
                        if (w = @ui_event_widgets[event_name])
                            w.show
                            w.update(*args)
                        else
                            puts "don't know what to do with UI event #{event_name}, " \
                                 "known events: #{@ui_event_widgets}"
                        end
                    end
                    on_connection_state_changed do |state|
                        @current_state = state
                        connection_state.update_state state
                    end
                    syskit.on_reachable do
                        @syskit_commands = syskit.client.syskit
                        @job_status_list.each_widget do |w|
                            w.show_actions = true
                        end
                        action_combo.clear
                        action_combo.enabled = true
                        syskit.actions.sort_by(&:name).each do |action|
                            next if action.advanced?

                            action_combo.add_item(
                                action.name, Qt::Variant.new(action.doc)
                            )
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

                SyskitRunArguments = Struct.new :robot, :set, keyword_init: true

                def syskit_run_arguments(robot: "default", set: [])
                    @syskit_run_arguments = SyskitRunArguments.new(
                        robot: robot, set: set
                    )
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

                    return unless has_quit

                    @syskit_pid = nil
                    run_hook :on_connection_state_changed, "UNREACHABLE"
                    @starting_monitor.stop
                end
                slots "monitor_syskit_startup()"

                def reset
                    Orocos.initialize
                    @logger_m = nil
                    @call_guards = {}
                    @orogen_models = {}

                    @port_read_manager&.dispose
                    @name_service&.dispose

                    @port_read_manager = Async::PortReadManager.new
                    @name_service = Async::NameService.new(
                        port_read_manager: @port_read_manager
                    )
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

                def create_app_start_actions
                    actions = {}

                    action = actions[:start] = Qt::Action.new("Start", self)
                    @starting_monitor = Qt::Timer.new
                    connect @starting_monitor, SIGNAL("timeout()"),
                            self, SLOT("monitor_syskit_startup()")
                    connect action, SIGNAL("triggered()") do
                        app_start(port: syskit.remote_port)
                    end
                    action = actions[:restart] = Qt::Action.new("Restart", self)
                    connect action, SIGNAL("triggered()") do
                        app_restart
                    end
                    action = actions[:quit] = Qt::Action.new("Quit", self)
                    connect action, SIGNAL("triggered()") do
                        app_quit
                    end

                    actions
                end

                def require_app_dir
                    begin
                        Roby.app.require_app_dir
                    rescue ArgumentError
                        Qt::MessageBox.warning(
                            self, "Wrong current directory",
                            "Current directory is not a Roby app, cannot start"
                        )
                        return
                    end

                    Roby.app.setup_robot_names_from_config_dir
                    true
                end

                def app_start(port: nil)
                    return unless require_app_dir

                    robot_name, start_controller, single = AppStartDialog.exec(
                        Roby.app.robots.names, self,
                        default_robot_name: @syskit_run_arguments.robot
                    )
                    return unless robot_name

                    extra_args = []
                    extra_args << "-r" << robot_name
                    extra_args << "-c" if start_controller
                    extra_args << "--interface-versions=2"
                    extra_args << "--port-v2=#{port}" if port
                    extra_args << "--single" if single
                    extra_args.concat(@syskit_run_arguments.set.map { "--set=#{_1}" })
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
                    @starting_monitor.start(100) if @syskit_pid
                    syskit.restart
                end

                def logger_task?(t)
                    return if @logger_m == false

                    @logger_m ||= Syskit::TaskContext
                                  .find_model_from_orogen_name("logger::Logger") || false
                    t.kind_of?(@logger_m) if @logger_m
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

                    @connection_state = GlobalStateLabel.new(
                        name: remote_name, actions: @global_actions.values
                    )
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
                        else
                            @batch_manager.hide
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
                    @ui_show_expanded_job.checked = true
                    @ui_show_expanded_job.connect SIGNAL("toggled(bool)") do |checked|
                        job_expanded_status.visible = checked
                    end

                    @ui_logging_configuration = LoggingConfiguration.new(syskit)

                    management_tab_widget = Qt::TabWidget.new(self)
                    management_tab_widget.addTab(task_inspector_widget, "Tasks")
                    management_tab_widget.addTab(ui_logging_configuration, "Logging")

                    splitter.add_widget(management_tab_widget)
                    job_expanded_status.set_size_policy(Qt::SizePolicy::MinimumExpanding,
                                                        Qt::SizePolicy::MinimumExpanding)
                    @main_layout.add_widget splitter, 1
                    w = splitter.size.width
                    splitter.sizes = [Integer(w * 0.25), Integer(w * 0.50),
                                      Integer(w * 0.25)]
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
                    layout.add_widget(
                        Qt::Label.new("oroGen configuration files changes on disk"), 1
                    )
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
                    label.set_size_policy(Qt::SizePolicy::Minimum,
                                          Qt::SizePolicy::Minimum)
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

                # @api private
                #
                # Sets up polling on a given syskit interface
                def poll_syskit_interface
                    if syskit.connected?
                        display_current_cycle_index_and_time
                        query_deployment_update
                        update_current_job_task_names if current_job
                        @port_read_manager.poll
                    else
                        reset_current_deployments
                        reset_current_job
                        reset_name_service
                        reset_task_inspector
                    end

                    syskit.poll
                end
                slots "poll_syskit_interface()"

                def display_current_cycle_index_and_time
                    return unless syskit.cycle_start_time

                    time_s = syskit.cycle_start_time.strftime("%H:%M:%S.%3N").to_s
                    progress_s = format(
                        "@%<index>i %<time>s", index: syskit.cycle_index, time: time_s
                    )
                    run_hook :on_progress, progress_s
                end

                def reset_current_job
                    @current_job = nil
                    @current_job_task_names = []

                    update_task_inspector(@name_service.tasks)
                end

                def process_current_deployments
                    update_name_service(@current_deployments)

                    if @current_job
                        update_task_inspector(@current_job_tasks)
                    else
                        update_task_inspector(@name_service.tasks)
                    end
                end

                def query_deployment_update
                    polling_call(
                        ["syskit"], "poll_ready_deployments",
                        known: @current_deployments.map(&:id)
                    ) do |updated, removed|
                        update_current_deployments(updated, removed)
                        process_current_deployments
                    end
                end

                def query_property_updates
                    polling_call(
                        ["syskit"], "poll_property_updates",
                        task_ids: @property_manager.known_task_ids,
                        since: @property_manager.poll_since
                    ) do |updates|
                        with_missing_types = @property_manager.process_updates(updates)
                        register_property_updates_with_missing_types(with_missing_types)
                        queue_registry_update unless with_missing_types.empty?
                    end
                end

                def update_current_deployments(updated, removed)
                    @current_deployments.delete_if do |d|
                        removed.include?(d.id)
                    end
                    @current_deployments.concat(updated)
                end

                def reset_current_deployments
                    @current_deployments = []
                    reset_task_inspector
                end

                def update_current_job_task_names
                    polling_call [], "tasks_of_job", @current_job.job_id do |tasks|
                        # TODO: handle asynchronicity, the tasks may not be already
                        # discovered and/or the
                        @current_job_tasks =
                            tasks
                            .map { _1.arguments[:orocos_name] }
                            .compact
                            .map { @name_service.find(_1) }
                    end
                end

                def update_task_inspector(tasks)
                    removed = @current_tasks - tasks
                    new     = tasks - @current_tasks
                    removed.each do |task|
                        ui_task_inspector.remove_task(task.name)
                    end
                    new.each do |task|
                        ui_task_inspector.add_task(task)
                    end
                    @current_tasks = tasks.dup
                end

                def reset_task_inspector
                    update_task_inspector([])
                end

                def polling_call(path, method_name, *args, **kw)
                    key = [path, method_name, args, kw]
                    return if @call_guards.key?(key) && @call_guards[key]

                    @call_guards[key] = true
                    syskit.async_call(path, method_name, *args, **kw) do |error, ret|
                        @call_guards[key] = false
                        if error
                            report_app_error(error)
                        else
                            yield(ret)
                        end
                    end
                end

                def async_call(path, method_name, *args)
                    syskit.async_call(path, method_name, *args) do |error, ret|
                        if error
                            report_app_error(error)
                        else
                            yield(ret)
                        end
                    end
                end

                def report_app_error(error)
                    warn error.message
                    error.backtrace.each do |line|
                        warn "  #{line}"
                    end
                end

                def update_name_service(deployments)
                    all_deployed_tasks = deployments.flat_map do |d|
                        d.deployed_tasks.find_all do |deployed_task|
                            model_name = deployed_task.orogen_model_name
                            !hide_loggers? || !OROGEN_LOGGER_NAMES.include?(model_name)
                        end
                    end
                    @name_service.async_update_tasks(all_deployed_tasks)
                end

                OROGEN_LOGGER_NAMES = %w[logger::Logger OroGen.logger.Logger].freeze

                def reset_name_service
                    @name_service.cleanup
                end

                def orogen_model_from_name(name)
                    @orogen_models[name] ||= Orocos.create_orogen_task_context_model(name)
                end

                # @api private
                #
                # Create the UI elements for the given job
                #
                # @param [Roby::Interface::Async::JobMonitor] job
                def monitor_job(job)
                    if job.respond_to?(:message)
                        puts job.message
                        return
                    end

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
                    reset_current_job
                    job_expanded_status.deselect
                end

                def select_job(job_status)
                    @current_job = job_status.job
                    @current_job_names = []
                    job_expanded_status.select(job_status)
                end

                def settings
                    @settings ||= Qt::Settings.new("syskit", "telemetry-ui")
                end

                def restore_from_settings(settings = self.settings)
                    self.size = settings.value(
                        "MainWindow/size", Qt::Variant.new(Qt::Size.new(800, 600))
                    ).to_size
                    %w[ui_hide_loggers ui_show_expanded_job].each do |checkbox_name|
                        default = Qt::Variant.new(send(checkbox_name).checked)
                        send(checkbox_name).checked = settings.value(checkbox_name,
                                                                     default).to_bool
                    end
                end

                def save_to_settings(settings = self.settings)
                    settings.set_value("MainWindow/size", Qt::Variant.new(size))
                    %w[ui_hide_loggers ui_show_expanded_job].each do |checkbox_name|
                        settings.set_value checkbox_name,
                                           Qt::Variant.new(send(checkbox_name).checked)
                    end
                end

                signals "fileOpenClicked(const QUrl&)"
            end
        end
    end
end
