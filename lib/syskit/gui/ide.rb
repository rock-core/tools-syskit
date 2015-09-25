require 'Qt'
require 'open3'
require 'syskit/gui/model_browser'
require 'syskit/gui/state_label'
require 'syskit/gui/testing'
require 'syskit/gui/runtime_state'
require 'shellwords'

module Syskit
    module GUI
        # The main Syskit IDE window
        class IDE < Qt::Widget
            attr_reader :layout
            attr_reader :btn_reload_models
            attr_reader :tab_widget
            attr_reader :model_browser
            attr_reader :runtime_state
            attr_reader :connection_state
            attr_reader :testing

            COLOR_INIT = "rgb(51, 181, 229)"
            COLOR_CONNECTED = "rgb(153, 204, 0)"
            COLOR_UNREACHABLE = "rgb(255, 68, 68)"
            CONNECTION_STATE_STYLE = "QLabel { font-size: 10pt; background-color: %s; }"
            CONNECTION_STATE_TEXT = "<b>%s</b>: %s"

            def initialize(parent = nil, host: 'localhost', runtime: false)
                super(parent)

                @layout = Qt::VBoxLayout.new(self)
                @tab_widget = Qt::TabWidget.new(self)
                @testing = Testing.new
                @model_browser = ModelBrowser.new

                syskit = Roby::Interface::Async::Interface.new(host)
                @runtime_state = RuntimeState.new(syskit: syskit)
                @btn_reload_models = Qt::PushButton.new("Reload Models", self)

                connect(model_browser, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SLOT('fileOpenClicked(const QUrl&)'))
                connect(runtime_state, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SLOT('fileOpenClicked(const QUrl&)'))

                layout.add_widget btn_reload_models
                layout.add_widget tab_widget
                browse_container = Qt::Widget.new
                browse_container_layout = Qt::VBoxLayout.new(browse_container)
                browse_container_layout.add_layout(testing.create_status_bar_ui)
                browse_container_layout.add_widget(model_browser)
                tab_widget.add_tab browse_container, "Browse"
                tab_widget.add_tab testing, "Testing"
                runtime_idx = tab_widget.add_tab runtime_state, "Runtime"
                @connection_state = GlobalStateLabel.new(
                    actions: runtime_state.global_actions.values,
                    name: runtime_state.remote_name)

                tab_widget.set_corner_widget(connection_state, Qt::TopLeftCorner)
                connect runtime_state, SIGNAL('connection_state_changed(bool)') do |flag|
                    connection_state_changed(flag)
                end
                connect runtime_state, SIGNAL('progress(QString)') do |message|
                    state = connection_state.current_state.to_s
                    connection_state.update_text("%s - %s" % [state, message])
                end

                model_browser.model_selector.filter_box.set_focus(Qt::OtherFocusReason)

                btn_reload_models.connect(SIGNAL('clicked()')) do
                    model_browser.registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    model_browser.update_exceptions
                    model_browser.reload
                    testing.reloaded
                end

                if runtime
                    tab_widget.current_index = runtime_idx
                end
            end

            def connection_state_changed(connected)
                if connected
                    connection_state.update_state 'CONNECTED'
                else
                    connection_state.update_state 'UNREACHABLE'
                end
            end

            def global_settings
                @global_settings ||= Qt::Settings.new('syskit')
            end

            def settings
                @settings ||= Qt::Settings.new('syskit', 'ide')
            end

            def restore_from_settings(settings = self.settings)
                self.size = settings.value("MainWindow/size", Qt::Variant.new(Qt::Size.new(800, 600))).to_size
                %w{model_browser}.each do |child_object_name|
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
                %w{model_browser}.each do |child_object_name|
                    settings.begin_group(child_object_name)
                    begin
                        send(child_object_name).save_to_settings(settings)
                    ensure
                        settings.end_group
                    end
                end
            end

            def fileOpenClicked(url)
                edit_cmd = global_settings.value('Main/cmdline', Qt::Variant.new)
                if edit_cmd.null?
                    Qt::MessageBox.warning(self, "Edit File", "No editor configured to open file #{url.to_string}. Edit #{global_settings.file_name} and add a cmdline= line in the [Main] section there. The %PATH and %LINENO placeholders will be replaced (if present) by the path and line number that should be edited")
                else
                    edit_cmd = edit_cmd.to_string.
                        gsub("%FILEPATH", url.to_local_file).
                        gsub("%LINENO", url.query_item_value('lineno'))

                    edit_cmd = Shellwords.shellsplit(edit_cmd)
                    stdin, stdout, stderr, wait_thr = Open3.popen3(*edit_cmd)
                    status = wait_thr.value
                    if !status.success?
                        Qt::MessageBox.warning(self, "Edit File", "Runninga \"#{edit_cmd.join('" "')}\" failed\n\nProcess reported: #{stderr.read}")
                    end
                end
            end
            slots 'fileOpenClicked(const QUrl&)'
        end
    end
end

