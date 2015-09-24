require 'roby/app/test_server'
require 'autorespawn'
module Syskit
    module GUI
        # GUI to interface with testing
        class Testing < Qt::Widget
            # @return [Roby::Application] the roby application we're working on
            attr_reader :app

            # @return [Autorespawn::Manager] the test manager
            attr_reader :manager

            # @return [Roby::App::TestServer] the test server that allow us to
            #   communicate with the tests
            attr_reader :server

            # Registered slaves
            #
            # @return [Hash<Numeric,(Autorespawn::Slave,Qt::StandardItem)>]
            attr_reader :slaves

            # PID-to-slave mapping
            #
            # @return [Hash<Integer,Autorespawn::Slave>]
            attr_reader :pid_to_slave

            # The item model that represents the subprocess state
            attr_reader :item_model
            attr_reader :test_list_ui
            attr_reader :test_result_ui

            # The timer used to call {#manager}.poll periodically
            attr_reader :poll_timer

            # Synchronization primitive between the DRb incoming thread and the
            # Qt thread
            attr_reader :work_queue

            # Synchronization primitive between the DRb incoming thread and the
            # Qt thread
            attr_reader :process_lock

            # Synchronization primitive between the DRb incoming thread and the
            # Qt thread
            attr_reader :process_sync

            # The count of slaves that are doing discovery
            attr_reader :discovery_count

            # The count of slaves that are doing discovery
            attr_reader :test_count

            # The label we use to display the test state
            attr_reader :status_label

            # The button that allows to start tests on and off
            attr_reader :start_stop_button

            def initialize(parent = nil, app: Roby.app, poll_period: 0.1)
                super(parent)
                @app = app
                @slaves = Hash.new
                @pid_to_slave = Hash.new

                @work_queue = Array.new
                @process_lock = Mutex.new
                @process_sync = ConditionVariable.new
                @discovery_count = 0
                @test_count = 0
                @running = false

                @manager = Autorespawn::Manager.new(name: Hash[models: ['syskit-ide']])
                @server  = Roby::App::TestServer.start(Process.pid)
                @item_model = Qt::StandardItemModel.new(self)
                create_ui
                test_list_ui.connect(SIGNAL('clicked(const QModelIndex&)')) do |index|
                    item = item_model.item_from_index(index)
                    display_item_details(item)
                end
                add_hooks

                start_stop_button.connect(SIGNAL('clicked()')) do
                    if running?
                        stop
                    else start
                    end
                end

                @poll_timer = Qt::Timer.new
                poll_timer.connect(SIGNAL('timeout()')) do
                    if running?
                        manager.poll
                    end
                    process_pending_work
                end
                poll_timer.start(Integer(poll_period * 1000))

                add_test_slaves
                notify_status_changed
            end

            def create_ui
                layout = Qt::VBoxLayout.new(self)

                status_bar = Qt::HBoxLayout.new
                status_bar.add_widget(@start_stop_button = Qt::PushButton.new("Start", self))
                status_bar.add_widget(@status_label = StateLabel.new(parent: self), 1)
                status_label.declare_state("STOPPED", :blue)
                status_label.declare_state("RUNNING", :green)
                layout.add_layout(status_bar)

                splitter = Qt::Splitter.new(self)
                layout.add_widget(splitter, 1)
                splitter.add_widget(@test_list_ui = Qt::ListView.new(self))
                test_list_ui.model = item_model
                test_list_ui.edit_triggers = Qt::AbstractItemView::NoEditTriggers
                splitter.add_widget(@test_result_ui = Qt::WebView.new(self))
            end

            def display_item_details(item)
                items = item.each_test_result.map do |r|
                    text = "#{r.test_case_name}::#{r.test_name}: #{r.failures.size} failures, #{r.assertions} assertions in %.3fs" % [r.time]
                    text = MetaRuby::GUI::HTML.escape_html(text)
                    "<li>#{text}</li>"
                end
                test_result_ui.html = "<html><ul>#{items.join("\n")}</ul></html>"
            end

            def running?
                @running
            end

            def start
                return if running?
                start_stop_button.text = "Stop"
                @running = true
                notify_status_changed
                emit started
            end

            def stop
                manager.kill
                process_pending_work
                start_stop_button.text = "Start"
                @running = false
                notify_status_changed
                emit stopped
            end
            slots 'start()', 'stop()'
            signals 'started()', 'stopped()'
            signals 'statsChanged()'

            Stats = Struct.new :test_count, :executed_test_count, :run_count, :failure_count, :assertions_count
            def stats
                stats = Stats.new(manager.slave_count, 0, 0, 0, 0)
                slaves.each_value do |_, slave|
                    stats.executed_test_count += 1 if slave.has_tested?
                    stats.run_count += slave.run_count
                    stats.failure_count += slave.failure_count
                    stats.assertions_count += slave.assertions_count
                end
                stats
            end

            def notify_status_changed
                stats = self.stats
                state_name = if running? then 'RUNNING'
                             else 'STOPPED'
                             end
                status_label.update_state(
                    state_name, text: "#{stats.test_count} tests, #{stats.executed_test_count} tests executed, #{stats.run_count} runs, #{stats.failure_count} failures and #{stats.assertions_count} assertions")
                emit statsChanged
            end

            # Call this after reloading the app so that the list of tests gets
            # refreshed as well
            def reloaded
                manager.clear
                add_test_slaves
            end

            class SubprocessItem < Qt::StandardItem
                SLAVE_OBJECT_ID_ROLE = Qt::UserRole + 1
                SLAVE_PID_ROLE = Qt::UserRole + 2

                COLORS = Hash[
                    blue: Qt::Color.new(51, 181, 229),
                    green: Qt::Color.new(153, 204, 0),
                    grey: Qt::Color.new(128, 128, 128),
                    red: Qt::Color.new(255, 68, 68)]

                NEW_SLAVE_BACKGROUND = COLORS[:blue]
                RUNNING_BACKGROUND   = COLORS[:green]
                SUCCESS_BACKGROUND   = COLORS[:grey]
                FAILED_BACKGROUND    = COLORS[:red]

                TestResult = Struct.new :file, :test_case_name, :test_name, :failures, :assertions, :time

                attr_reader :slave
                attr_reader :name
                attr_reader :test_results
                attr_reader :exceptions

                attr_reader :assertions_count
                attr_reader :failure_count

                def initialize(app, slave)
                    super()

                    clear

                    @has_tested = false
                    @slave = slave
                    name = (slave.name[:path] || '<Unknown>')
                    if base_path = app.find_base_path_for(name)
                        name = File.basename(base_path) + ":" + name[(base_path.size + 1)..-1]
                    end
                    @name = name

                    self.text = name
                    self.background = Qt::Brush.new(Qt::Color.new(NEW_SLAVE_BACKGROUND))
                    self.slave_object_id = slave.object_id
                end

                def each_test_result(&block)
                    test_results.each(&block)
                end

                def run_count
                    test_results.size
                end

                def slave_object_id
                    data(SLAVE_OBJECT_ID_ROLE).to_long_long
                end

                def slave_object_id=(id)
                    set_data(Qt::Variant.new(id), SLAVE_OBJECT_ID_ROLE)
                end

                def slave_pid=(pid)
                    set_data(Qt::Variant.new(pid), SLAVE_PID_ROLE)
                end

                def slave_pid(pid)
                    data(SLAVE_PID_ROLE).to_int
                end

                def pending
                    self.background = Qt::Brush.new(Qt::Color.new(NEW_SLAVE_BACKGROUND))
                end

                def start
                    self.background = Qt::Brush.new(Qt::Color.new(RUNNING_BACKGROUND))
                    clear
                end

                def finished
                    if has_failures? || has_exceptions?
                        self.background = Qt::Brush.new(Qt::Color.new(FAILED_BACKGROUND))
                    elsif has_tested?
                        self.background = Qt::Brush.new(Qt::Color.new(SUCCESS_BACKGROUND))
                    else
                        self.background = Qt::Brush.new(Qt::Color.new(NEW_SLAVE_BACKGROUND))
                    end
                end

                def update_text
                    if has_tested?
                        self.text = "#{name}\n#{test_results.size} tests, #{failure_count} failures, #{assertions_count} assertions"
                    else
                        self.text = name
                    end
                end

                def discovery_start
                end

                def discovery_finished
                end

                def test_start
                    @has_tested = true
                    update_text
                end

                def test_finished
                end

                def has_failures?
                    failure_count > 0
                end

                def has_exceptions?
                    !exceptions.empty?
                end

                def has_tested?
                    @has_tested
                end

                def add_test_result(file, test_case_name, test_name, failures, assertions, time)
                    @failure_count += failures.size
                    @assertions_count += assertions
                    test_results << TestResult.new(file, test_case_name, test_name, failures, assertions, time)
                    update_text
                end

                def add_exception(e)
                    exceptions << e
                end

                def clear
                    @failure_count = 0
                    @assertions_count = 0
                    @test_results = Array.new
                    @exceptions = Array.new
                end
            end

            # Resolves a slave item from its object
            #
            # @raise [ArgumentError] if no such slave has been registered with
            #   {#register_slave}
            def item_from_slave(slave)
                if info = slaves[slave.object_id]
                    return info[1]
                else
                    raise ArgumentError, "#{slave} is not registered"
                end
            end

            # Resolves a slave from its PID
            #
            # @raise [ArgumentError] if there is no slave associated to this PID
            def slave_from_pid(pid)
                if slave = pid_to_slave[pid]
                    return slave
                else
                    raise ArgumentError, "no slave registered for PID #{pid}"
                end
            end

            # Resolves an item from the slave PID
            #
            # @raise [ArgumentError] if there is no slave for the given PID
            def item_from_pid(pid)
                item_from_slave(slave_from_pid(pid))
            end

            # Register a new slave and add it to the item model
            def register_slave(slave)
                item = SubprocessItem.new(app, slave)
                slaves[slave.object_id] = [slave, item]
                item_model.append_row(item)
            end

            # Register a PID-to-slave mapping
            #
            # @param [Autorespawn::Slave] slave the slave, whose {#pid}
            #   attribute is expected to be set appropriately
            def register_slave_pid(slave)
                item = item_from_slave(slave)
                pid_to_slave[slave.pid] = slave
                item.slave_pid = slave.pid
            end

            # Deregister a PID-to-slave mapping
            #
            # @param [Integer] pid
            def deregister_slave_pid(pid)
                if !(slave = pid_to_slave.delete(pid))
                    raise ArgumentError, "no slave registered for PID #{pid}"
                end
            end

            def process_pending_work
                process_lock.synchronize do
                    while !work_queue.empty?
                        work_queue.shift.call
                    end
                    process_sync.signal
                end
            end


            def queue_work(&block)
                process_lock.synchronize do
                    work_queue << block
                end
            end

            def process(&block)
                process_lock.synchronize do
                    work_queue << block
                    process_sync.wait(process_lock)
                end
            end

            # Add hooks on {#manager} and {#server} that will allow us to track
            # the test progress
            def add_hooks
                manager.on_slave_new do |slave|
                    queue_work do
                        register_slave(slave)
                        notify_status_changed
                    end
                end
                manager.on_slave_start do |slave|
                    queue_work do
                        register_slave_pid(slave)
                        item_from_slave(slave).start
                        notify_status_changed
                    end
                end
                manager.on_slave_finished do |slave|
                    queue_work do
                        deregister_slave_pid(slave.pid)
                        item_from_slave(slave).finished
                    end
                end
                server.on_exception do |pid, exception|
                    queue_work do
                        item_from_pid(pid).add_exception(exception)
                    end
                end
                server.on_discovery_start do |pid|
                    queue_work do
                        @discovery_count += 1
                        item_from_pid(pid).discovery_start
                    end
                end
                server.on_discovery_finished do |pid|
                    queue_work do
                        @discovery_count -= 1
                        item_from_pid(pid).discovery_finished
                    end
                end
                server.on_test_start do |pid|
                    queue_work do
                        @test_count += 1
                        item_from_pid(pid).test_start
                    end
                end
                server.on_test_result do |pid, file, test_case_name, test_name, failures, assertions, time|
                    queue_work do
                        item_from_pid(pid).
                            add_test_result(file, test_case_name, test_name, failures, assertions, time)
                        notify_status_changed
                    end
                end
                server.on_test_finished do |pid|
                    queue_work do
                        @test_count -= 1
                        item_from_pid(pid).test_finished
                    end
                end
            end

            def add_test_slaves
                models_per_file = Hash.new { |h, k| h[k] = Set.new }
                app.each_model do |m|
                    next if m.respond_to?(:has_ancestor?) && m.has_ancestor?(Roby::Event)
                    next if m.respond_to?(:private_specialization?) && m.private_specialization?
                    next if !m.name
                    if path = app.test_file_for(m)
                        models_per_file[path] << m
                    end
                end

                models_per_file.each do |path, models|
                    process_id = Hash[path: path, models: models.map(&:name).sort]
                    slave = manager.add_slave(
                        Gem.ruby, '-S', 'roby', 'autotest', '--server', server.server_id.to_s, path,
                        name: process_id)
                    slave.register_files([Pathname.new(path)])
                end
            end
        end
    end
end
