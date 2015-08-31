require 'Qt'
require 'open3'
require 'syskit/gui/model_browser'
require 'shellwords'
module Syskit
    module GUI
        # The main Syskit IDE window
        class IDE < Qt::Widget
            attr_reader :layout
            attr_reader :btn_reload_models
            attr_reader :tab_widget
            attr_reader :model_browser

            def initialize(parent = nil)
                super

                @layout = Qt::VBoxLayout.new(self)
                @tab_widget = Qt::TabWidget.new(self)
                @model_browser = ModelBrowser.new
                @btn_reload_models = Qt::PushButton.new("Reload Models", self)

                connect(model_browser, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SLOT('fileOpenClicked(const QUrl&)'))

                layout.add_widget btn_reload_models
                layout.add_widget tab_widget
                tab_widget.add_tab model_browser, "Browse"

                model_browser.model_selector.filter_box.set_focus(Qt::OtherFocusReason)

                btn_reload_models.connect(SIGNAL('clicked()')) do
                    model_browser.registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    model_browser.update_exceptions
                    model_browser.reload
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

