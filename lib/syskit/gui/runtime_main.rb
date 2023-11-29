# frozen_string_literal: true

require "Qt"
require "open3"
require "shellwords"
require "syskit/gui/runtime_state"

module Syskit
    module GUI
        # The main Syskit IDE window
        class RuntimeMain < Qt::Widget
            attr_reader :layout
            attr_reader :tab_widget
            attr_reader :runtime_state
            attr_reader :connection_state

            def initialize(
                parent = nil,
                host: "localhost", port: Roby::Interface::DEFAULT_PORT,
                robot_name: "default"
            )
                super(parent)

                @layout = Qt::VBoxLayout.new(self)
                @tab_widget = Qt::TabWidget.new(self)
                @layout.add_widget tab_widget
                @robot_name = "default"

                syskit = Roby::Interface::Async::Interface.new(host, port: port)
                create_runtime_state_ui(syskit, robot_name: robot_name)
                tab_widget.add_tab runtime_state, "Runtime"
                connect(@runtime_state, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SLOT("fileOpenClicked(const QUrl&)"))
            end

            def create_runtime_state_ui(syskit, robot_name: "default") # rubocop:disable Metrics/AbcSize
                @runtime_state = RuntimeState.new(syskit: syskit, robot_name: robot_name)
                connect(runtime_state, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SLOT("fileOpenClicked(const QUrl&)"))
                @connection_state = GlobalStateLabel.new(
                    actions: runtime_state.global_actions.values,
                    name: runtime_state.remote_name
                )
                @connection_state.connect(SIGNAL("clicked(QPoint)")) do |global_pos|
                    @connection_state.app_state_menu(global_pos)
                end

                tab_widget.set_corner_widget(connection_state, Qt::TopLeftCorner)
                runtime_state.on_connection_state_changed do |state|
                    connection_state.update_state state
                end
                runtime_state.on_progress do |message|
                    state = connection_state.current_state.to_s
                    connection_state.update_text(
                        format("%<state>s - %<message>s", state: state, message: message)
                    )
                end
            end

            def global_settings
                @global_settings ||= Qt::Settings.new("syskit")
            end

            def settings
                @settings ||= Qt::Settings.new("syskit", "runtime")
            end

            def restore_from_settings(settings = self.settings)
                self.size = settings.value(
                    "MainWindow/size", Qt::Variant.new(Qt::Size.new(800, 600))
                ).to_size
                %w[runtime_state].each do |child_object_name|
                    next unless send(child_object_name)

                    settings.begin_group(child_object_name)
                    begin
                        send(child_object_name).restore_from_settings(settings)
                    ensure
                        settings.end_group
                    end
                end
            end

            def save_to_settings(settings = self.settings)
                settings.set_value("MainWindow/size", Qt::Variant.new(size))
                %w[runtime_state].each do |child_object_name|
                    next unless send(child_object_name)

                    settings.begin_group(child_object_name)
                    begin
                        send(child_object_name).save_to_settings(settings)
                    ensure
                        settings.end_group
                    end
                end
            end

            def fileOpenClicked(url) # rubocop:disable Naming/MethodName
                edit_cmd = global_settings.value("Main/cmdline", Qt::Variant.new)
                if edit_cmd.null?
                    Qt::MessageBox.warning(
                        self, "Edit File", "No editor configured to open file "\
                        "#{url.to_string}. Edit #{global_settings.file_name} and "\
                        "add a cmdline= line in the [Main] section there. The %PATH "\
                        "and %LINENO placeholders will be replaced (if present) "\
                        "by the path and line number that should be edited"
                    )
                    return
                end

                run_edit_command(edit_cmd.to_string, url)
            end
            slots "fileOpenClicked(const QUrl&)"

            def run_edit_command(edit_cmd, url)
                edit_cmd = edit_cmd
                           .to_string
                           .gsub("%FILEPATH", url.to_local_file)
                           .gsub("%LINENO", url.query_item_value("lineno") || "0")

                edit_cmd = Shellwords.shellsplit(edit_cmd)
                _, _, stderr, wait_thr = Open3.popen3(*edit_cmd)
                status = wait_thr.value
                return if status.success?

                Qt::MessageBox.warning(
                    self, "Edit File",
                    "Runninga \"#{edit_cmd.join('" "')}\" failed\n\n"\
                    "Process reported: #{stderr.read}"
                )
            end
        end
    end
end
