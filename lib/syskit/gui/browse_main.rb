# frozen_string_literal: true

require "Qt"
require "open3"
require "shellwords"

require "syskit/gui/model_browser"
require "syskit/gui/testing"
require "roby/droby/plan_rebuilder"

module Syskit
    module GUI
        # The main Syskit IDE window
        class BrowseMain < Qt::Widget
            attr_reader :layout
            attr_reader :btn_reload_models
            attr_reader :tab_widget
            attr_reader :model_browser
            attr_reader :testing

            def initialize(parent = nil, tests: false, robot_name: "default")
                super(parent)

                @layout = Qt::VBoxLayout.new(self)
                @tab_widget = Qt::TabWidget.new(self)
                @layout.add_widget tab_widget
                @robot_name = robot_name

                @testing = Testing.new
                @model_browser = ModelBrowser.new
                @btn_reload_models = Qt::PushButton.new("Reload Models", self)
                @btn_add = Qt::PushButton.new("Add", self)
                btn_add_menu = Qt::Menu.new
                btn_add_menu.add_action "OroGen Project"
                btn_add_menu.add_action "OroGen Type"
                btn_add_menu.add_action "Model File"
                btn_add_menu.connect(SIGNAL("triggered(QAction*)")) do |action|
                    case action.text
                    when "OroGen Project"
                        add_orogen_project
                    when "OroGen Type"
                        add_orogen_type
                    when "Model File"
                        add_model_file
                    end
                end
                @btn_add.menu = btn_add_menu

                connect(model_browser, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SLOT("fileOpenClicked(const QUrl&)"))
                connect(testing, SIGNAL("fileOpenClicked(const QUrl&)"),
                        self, SLOT("fileOpenClicked(const QUrl&)"))

                browse_container = Qt::Widget.new
                browse_container_layout = Qt::VBoxLayout.new(browse_container)
                status_bar = testing.create_status_bar_ui
                status_bar.insert_widget(0, @btn_reload_models)
                status_bar.insert_widget(1, @btn_add)
                browse_container_layout.add_layout(status_bar)
                browse_container_layout.add_widget(model_browser)
                tab_widget.add_tab browse_container, "Browse"
                tab_widget.add_tab testing, "Testing"

                btn_reload_models.connect(SIGNAL("clicked()")) do
                    reload_models
                end
                model_browser.model_selector.filter_box.set_focus(Qt::OtherFocusReason)

                testing.start if tests
            end

            def reload_models
                model_browser.registered_exceptions.clear
                Roby.app.clear_exceptions
                Roby.app.cleanup
                Roby.app.clear_models
                Roby.app.clear_config
                Roby.app.setup
                # HACK: reload_models calls Runkit.clear, which actually
                # HACK: de-initializes Runkit. Overall, this isn't a problem
                # HACK: on the Syskit side as one is not supposed to reload
                # HACK: the models while the app is setup (setup being
                # HACK: what calls Runkit.initialize). However, the IDE also
                # HACK: has a task inspector, which also needs
                # HACK: Runkit.initialize, so the IDE *does* call initialize
                # HACK: explicitely
                model_browser.update_exceptions
                model_browser.reload
                testing.reloaded
            end

            class Picker < Qt::Dialog
                def initialize(parent, items)
                    super(parent)

                    model = Qt::StringListModel.new(self)
                    model.string_list = items.sort
                    @filter = Qt::SortFilterProxyModel.new(self)
                    @filter.dynamic_sort_filter = true
                    @filter.source_model = model

                    @filter_text = Qt::LineEdit.new(self)
                    @filter_text.connect(SIGNAL("textChanged(QString)")) do |text|
                        @filter.filterRegExp = Qt::RegExp.new(text)
                    end
                    @list = Qt::ListView.new(self)
                    @list.edit_triggers = Qt::AbstractItemView::NoEditTriggers
                    @list.model = @filter
                    @list.connect(SIGNAL("doubleClicked(const QModelIndex&)")) do |index|
                        accept
                    end
                    @list.current_index = @filter.index(0, 0)

                    resize(500, 500)

                    layout = Qt::VBoxLayout.new(self)
                    layout.add_widget(@filter_text)
                    layout.add_widget(@list)

                    buttons = Qt::DialogButtonBox.new(
                        Qt::DialogButtonBox::Ok | Qt::DialogButtonBox::Cancel
                    )
                    connect(buttons, SIGNAL("accepted()"), self, SLOT("accept()"))
                    connect(buttons, SIGNAL("rejected()"), self, SLOT("reject()"))
                    layout.add_widget(buttons)
                end

                def self.select(parent, items)
                    if items.empty?
                        Qt::MessageBox.information(parent, "Nothing to pick",
                                                   "There is nothing to pick from")
                        return
                    end
                    new(parent, items).select
                end

                def select
                    result = exec
                    if result == Qt::Dialog::Accepted
                        @filter.data(@list.current_index)
                               .to_string
                    end
                end
            end

            def add_orogen_project
                loader = Roby.app.default_pkgconfig_loader
                model_names = loader.each_available_task_model_name.to_a
                syskit2orogen = model_names
                                .each_with_object({}) do |(orogen_name, project_name), result|
                    unless loader.has_loaded_project?(project_name)
                        syskit_path = ["OroGen", *orogen_name.split("::")]
                        syskit_name = syskit_path.join(".")
                        result[syskit_name] = [syskit_path, project_name]
                    end
                end

                if (selected = Picker.select(self, syskit2orogen.keys))
                    syskit_path, project_name = syskit2orogen[selected]
                    Roby.app.using_task_library(project_name)
                    Roby.app.extra_required_task_libraries << project_name
                    @model_browser.reload
                    @model_browser.select_by_path(*syskit_path)
                end
            end

            def add_orogen_type
                loader = Roby.app.default_pkgconfig_loader
                syskit2orogen = loader.each_available_type_name
                                      .each_with_object({}) do |(type_name, typekit_name, _), result|
                    next if type_name.end_with?("_m")
                    next if type_name =~ /\[/

                    unless loader.has_loaded_typekit?(typekit_name)
                        syskit_path = ["Types", *Typelib.split_typename(type_name)]
                        syskit_name = syskit_path.join(".")
                        result[syskit_name] = [syskit_path, typekit_name]
                    end
                end

                if (selected = Picker.select(self, syskit2orogen.keys))
                    syskit_path, typekit_name = syskit2orogen[selected]
                    Roby.app.extra_required_typekits << typekit_name
                    Roby.app.import_types_from(typekit_name)
                    @model_browser.reload
                    @model_browser.select_by_path(*syskit_path)
                end
            end

            def add_model_file
                models_dir = File.join(Roby.app.app_dir, "models")
                initial_dir =
                    if File.directory?(models_dir)
                        models_dir
                    else
                        Roby.app.app_dir
                    end

                existing_models = Roby.app.root_models
                                      .flat_map { |root| root.each_submodel.to_a }
                                      .to_set

                files = Qt::FileDialog.getOpenFileNames(
                    self, "Pick model file(s) to add", initial_dir
                )
                files.each do |path|
                    Roby.app.require(path)
                    Roby.app.additional_model_files << path
                    @model_browser.update_exceptions
                    @model_browser.reload
                end

                new_models = []
                Roby.app.root_models.each do |root|
                    root.each_submodel do |m|
                        new_models << m unless existing_models.include?(m)
                    end
                end

                orogen_based, other = new_models.partition do |m|
                    m.kind_of?(Module) &&
                        m <= Syskit::TaskContext &&
                        !(m <= Syskit::RubyTaskContext)
                end
                if (new_model = other.first || orogen_based.first)
                    @model_browser.select_by_model(new_model)
                end
            end

            def global_settings
                @global_settings ||= Qt::Settings.new("syskit")
            end

            def settings
                @settings ||= Qt::Settings.new("syskit", "browse")
            end

            def restore_from_settings(settings = self.settings)
                self.size = settings.value("MainWindow/size", Qt::Variant.new(Qt::Size.new(800, 600))).to_size
                %w[model_browser testing].each do |child_object_name|
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
                %w[model_browser testing].each do |child_object_name|
                    next unless send(child_object_name)

                    settings.begin_group(child_object_name)
                    begin
                        send(child_object_name).save_to_settings(settings)
                    ensure
                        settings.end_group
                    end
                end
            end

            def fileOpenClicked(url)
                edit_cmd = global_settings.value("Main/cmdline", Qt::Variant.new)
                if edit_cmd.null?
                    Qt::MessageBox.warning(self, "Edit File", "No editor configured to open file #{url.to_string}. Edit #{global_settings.file_name} and add a cmdline= line in the [Main] section there. The %PATH and %LINENO placeholders will be replaced (if present) by the path and line number that should be edited")
                else
                    edit_cmd = edit_cmd.to_string
                                       .gsub("%FILEPATH", url.to_local_file)
                                       .gsub("%LINENO", url.query_item_value("lineno") || "0")

                    edit_cmd = Shellwords.shellsplit(edit_cmd)
                    stdin, stdout, stderr, wait_thr = Open3.popen3(*edit_cmd)
                    status = wait_thr.value
                    unless status.success?
                        Qt::MessageBox.warning(self, "Edit File", "Runninga \"#{edit_cmd.join('" "')}\" failed\n\nProcess reported: #{stderr.read}")
                    end
                end
            end
            slots "fileOpenClicked(const QUrl&)"
        end
    end
end
