require 'syskit'
require 'roby/interface/async'
require 'roby/interface/async/log'
require 'syskit/gui/logging_configuration'
require 'syskit/gui/job_status_display'
require 'syskit/gui/widget_list'
require 'syskit/gui/expanded_job_status'
require 'syskit/gui/global_state_label'
require 'syskit/gui/app_start_dialog'

module Syskit
    module GUI
        # UI that displays and allows to control jobs
        class RuntimeState < Qt::Widget
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

            class ActionListDelegate < Qt::StyledItemDelegate
                OUTER_MARGIN = 5
                INTERLINE    = 3
                def sizeHint(option, index)
                    fm = option.font_metrics
                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    Qt::Size.new(
                        [fm.width(main), fm.width(doc)].max + 2 * OUTER_MARGIN,
                        fm.height * 2 + OUTER_MARGIN * 2 + INTERLINE)
                end

                def paint(painter, option, index)
                    painter.save

                    if (option.state & Qt::Style::State_Selected) != 0
                        painter.fill_rect(option.rect, option.palette.highlight)
                        painter.brush = option.palette.highlighted_text
                    end

                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    text_bounds = Qt::Rect.new

                    fm = option.font_metrics
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, main, text_bounds)

                    font = painter.font
                    font.italic = true
                    painter.font = font
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, doc, text_bounds)
                ensure
                    painter.restore
                end
            end

            # @param [Roby::Interface::Async::Interface] syskit the underlying
            #   syskit interface
            # @param [Integer] poll_period how often should the syskit interface
            #   be polled (milliseconds). Set to nil if the polling is already
            #   done externally
            def initialize(parent: nil, syskit: Roby::Interface::Async::Interface.new, poll_period: 10)
                super(parent)

                orocos_corba_nameservice = Orocos::CORBA::NameService.new(syskit.remote_name)
                @name_service = Orocos::Async::NameService.new(orocos_corba_nameservice)

                if poll_period
                    poll_syskit_interface(syskit, poll_period)
                end

                @syskit = syskit
                create_ui

                @global_actions = Hash.new
                action = global_actions[:start]   = Qt::Action.new("Start", self)
                connect action, SIGNAL('triggered()') do
                    app_start
                end
                action = global_actions[:restart] = Qt::Action.new("Restart", self)
                connect action, SIGNAL('triggered()') do
                    app_restart
                end
                action = global_actions[:quit]    = Qt::Action.new("Quit", self)
                connect action, SIGNAL('triggered()') do
                    app_quit
                end

                @current_job = nil
                @current_orocos_tasks = Set.new
                @all_tasks = Set.new
                @all_job_info = Hash.new
                syskit.on_reachable do
                    update_log_server_connection(syskit.client.log_server_port)
                    action_combo.clear
                    syskit.actions.sort_by(&:name).each do |action|
                        next if action.advanced?
                        action_combo.add_item(action.name, Qt::Variant.new(action.doc))
                    end
                    ui_logging_configuration.refresh
                    global_actions[:start].visible = false
                    global_actions[:restart].visible = true
                    global_actions[:quit].visible = true
                    connection_state.update_state 'CONNECTED'
                    emit connection_state_changed(true)
                end
                syskit.on_unreachable do
                    if remote_name == 'localhost'
                        global_actions[:start].visible = true
                    end
                    ui_logging_configuration.refresh
                    global_actions[:restart].visible = false
                    global_actions[:quit].visible = false
                    connection_state.update_state 'UNREACHABLE'
                    emit connection_state_changed(false)
                end
                syskit.on_job do |job|
                    job.start
                    monitor_job(job)
                end
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
                    emit progress("loading %02i" % [Float(rx) / expected * 100])
                end
                syskit_log_stream.on_update do |cycle_index, cycle_time|
                    if syskit_log_stream.init_done?
                        time_s = "#{cycle_time.strftime('%H:%M:%S')}.#{'%.03i' % [cycle_time.tv_usec / 1000]}"
                        emit progress("@%i %s" % [cycle_index, time_s])

                        job_expanded_status.update_time(cycle_index, cycle_time)
                        update_tasks_info
                        job_expanded_status.add_tasks_info(all_tasks, all_job_info)
                        job_expanded_status.scheduler_state = syskit_log_stream.scheduler_state
                        job_expanded_status.update_chronicle
                    end
                    syskit_log_stream.clear_integrated
                end
            end

            def hide_loggers?
                !@ui_hide_loggers.checked?
            end

            signals 'progress(QString)'
            signals 'connection_state_changed(bool)'

            def remote_name
                syskit.remote_name
            end

            def app_start
                robot_name, start_controller = AppStartDialog.exec(Roby.app.robots.names, self)
                if robot_name
                    extra_args = Array.new
                    if !robot_name.empty?
                        extra_args << "-r#{robot_name}"
                    end
                    if start_controller
                        extra_args << "-c"
                    end
                    Kernel.spawn Gem.ruby, '-S', 'syskit', 'run', *extra_args,
                        pgroup: true
                end
            end

            def app_quit
                syskit.quit
            end

            def app_restart
                syskit.restart
            end

            def update_tasks_info
                if current_job
                    job_task = syskit_log_stream.plan.find_tasks(Roby::Interface::Job).
                        with_arguments(job_id: current_job.job_id).
                        first
                    return if !job_task
                    placeholder_task = job_task.planned_task
                    return if !placeholder_task

                    dependency = placeholder_task.relation_graph_for(Roby::TaskStructure::Dependency)
                    tasks = dependency.enum_for(:depth_first_visit, placeholder_task).to_a
                    tasks << job_task
                else
                    tasks = syskit_log_stream.plan.tasks
                end

                all_tasks.merge(tasks.to_set)
                if hide_loggers?
                    all_tasks.delete_if do |t|
                        t.model.ancestors.any? { |t| t.name == "OroGen::Logger::Logger" }
                    end
                end
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
                candidate_tasks = self.all_tasks.
                    find_all { |t| t.kind_of?(Syskit::TaskContext) }
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

            def create_ui
                job_summary = Qt::Widget.new
                job_summary_layout = Qt::VBoxLayout.new(job_summary)
                job_summary_layout.add_layout(@new_job_layout  = create_ui_new_job)
                job_summary_layout.add_widget(@job_status_list = WidgetList.new(self))

                @connection_state = GlobalStateLabel.new(name: remote_name)
                connection_state.declare_state 'CONNECTED', :green
                connection_state.declare_state 'UNREACHABLE', :red
                connect self, SIGNAL('progress(QString)') do |message|
                    state = connection_state.current_state.to_s
                    connection_state.update_text("%s - %s" % [state, message])
                end
                job_status_list.add_widget connection_state
                connection_state.connect(SIGNAL('clicked()')) do
                    deselect_job
                end

                main_layout = Qt::VBoxLayout.new(self)
                splitter = Qt::Splitter.new
                splitter.add_widget job_summary
                splitter.add_widget(@job_expanded_status = ExpandedJobStatus.new)

                task_inspector_widget = Qt::Widget.new
                task_inspector_layout = Qt::VBoxLayout.new(task_inspector_widget)
                task_inspector_layout.add_widget(@ui_hide_loggers = Qt::CheckBox.new("Show loggers"))
                task_inspector_layout.add_widget(@ui_task_inspector = Vizkit.default_loader.TaskInspector)
                @ui_hide_loggers.checked = false

                @ui_logging_configuration = LoggingConfiguration.new(syskit)

                management_tab_widget = Qt::TabWidget.new(self)
                management_tab_widget.addTab(task_inspector_widget, "Tasks")
                management_tab_widget.addTab(ui_logging_configuration, "Logging")

                splitter.add_widget(management_tab_widget)
                job_expanded_status.set_size_policy(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::MinimumExpanding)
                main_layout.add_widget splitter
                w = splitter.size.width
                splitter.sizes = [Integer(w * 0.25), Integer(w * 0.50), Integer(w * 0.25)]
            end

            def create_ui_new_job
                new_job_layout = Qt::HBoxLayout.new
                label   = Qt::Label.new("New Job", self)
                label.set_size_policy(Qt::SizePolicy::Minimum, Qt::SizePolicy::Minimum)
                @action_combo = Qt::ComboBox.new(self)
                action_combo.item_delegate = ActionListDelegate.new(self)
                new_job_layout.add_widget label
                new_job_layout.add_widget action_combo, 1
                action_combo.connect(SIGNAL('activated(QString)')) do |action_name|
                    create_new_job(action_name)
                end
                new_job_layout
            end

            class NewJobDialog < Qt::Dialog
                attr_reader :editor

                def initialize(parent = nil, text = '')
                    super(parent)
                    resize(800, 600)

                    layout = Qt::VBoxLayout.new(self)
                    @error_message = Qt::Label.new(self)
                    @error_message.style_sheet = "QLabel { background-color: #ffb8b9; border: 1px solid #ff6567; padding: 5px; }"
                    @error_message.frame_style = Qt::Frame::StyledPanel
                    layout.add_widget(@error_message)
                    @error_message.hide

                    @editor = Qt::TextEdit.new(self)
                    self.text = text
                    layout.add_widget editor

                    buttons = Qt::DialogButtonBox.new(Qt::DialogButtonBox::Ok | Qt::DialogButtonBox::Cancel)
                    buttons.connect(SIGNAL('accepted()')) do
                        begin
                            @error_message.hide
                            @result = Parser.parse(self.text)
                            accept
                        rescue Exception => e
                            @error_message.text = e.message
                            @error_message.show
                        end
                    end
                    buttons.connect(SIGNAL('rejected()')) { reject }
                    layout.add_widget buttons
                end

                def self.exec(parent, text)
                    new(parent, text).exec
                end

                class Parser < BasicObject
                    def self.const_missing(const_name)
                        ::Object.const_get(const_name)
                    end

                    def self.parse(text)
                        parser = new
                        parser.instance_eval(text)
                        parser.__result
                    end

                    def method_missing(m, **options)
                        @method_name = m
                        @method_options = options
                    end

                    def __result
                        return @method_name, @method_options
                    end
                end

                def result
                    @result
                end

                def text=(text)
                    editor.plain_text = text
                end

                def text
                    editor.to_plain_text
                end
            end

            def create_new_job(action_name)
                action_model = syskit.actions.find { |m| m.name == action_name }
                if !action_model
                    raise ArgumentError, "no action named #{action_name} found"
                end

                if action_model.arguments.empty?
                    syskit.client.send("#{action_name}!", Hash.new)
                else
                    formatted_arguments = String.new
                    action_model.arguments.each do |arg|
                        if !formatted_arguments.empty?
                            formatted_arguments << ",\n"
                        end
                        formatted_arguments << "  # #{arg.doc}\n"
                        if arg.required?
                            formatted_arguments << "  #{arg.name}: "
                        elsif arg.default.nil?
                            formatted_arguments << "  #{arg.name}: nil"
                        else
                            formatted_arguments << "  #{arg.name}: #{arg.default}"
                        end
                    end
                    formatted_action = "#{action_name}!(\n#{formatted_arguments}\n)"
                    dialog = NewJobDialog.new(self, formatted_action)
                    if dialog.exec == Qt::Dialog::Accepted
                        action_name, action_options = dialog.result
                        syskit.client.send(action_name, action_options)
                    end
                end
            end

            attr_reader :syskit_poll

            # @api private
            #
            # Sets up polling on a given syskit interface
            def poll_syskit_interface(syskit, period)
                @syskit_poll = Qt::Timer.new
                syskit_poll.connect(SIGNAL('timeout()')) do
                    syskit.poll
                    if syskit_log_stream
                        if syskit_log_stream.poll(max: 0.05) == Roby::Interface::Async::Log::STATE_PENDING_DATA
                            syskit_poll.interval = 0
                        else
                            syskit_poll.interval = period
                        end
                    end
                end
                syskit_poll.start(period)
                syskit
            end

            # @api private
            #
            # Create the UI elements for the given job
            #
            # @param [Roby::Interface::Async::JobMonitor] job
            def monitor_job(job)
                job_status = JobStatusDisplay.new(job)
                job_status_list.add_widget job_status
                job_status.connect(SIGNAL('clicked()')) do
                    select_job(job_status)
                end
                connect(job_status, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SIGNAL('fileOpenClicked(const QUrl&)'))
            end

            def deselect_job
                @current_job = nil
                job_expanded_status.deselect
                all_tasks.clear
                all_job_info.clear
                if syskit_log_stream
                    update_tasks_info
                end
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            def select_job(job_status)
                @current_job = job_status.job
                all_tasks.clear
                all_job_info.clear
                update_tasks_info
                job_expanded_status.select(job_status)
                job_expanded_status.add_tasks_info(all_tasks, all_job_info)
            end

            signals 'fileOpenClicked(const QUrl&)'
        end
    end
end

