require 'syskit/gui/ruby_module_model'
module Syskit
    module GUI
        class ModelSelector < Qt::Widget
            attr_reader :btn_display_compositions
            attr_reader :btn_display_data_services
            attr_reader :btn_display_task_contexts
            attr_reader :btn_display_profiles
            attr_reader :model_list
            attr_reader :model_filter
            attr_reader :browser_model

            def initialize(parent = nil)
                super

                layout = Qt::VBoxLayout.new(self)
                setup_filter_gui_elements(layout)
                setup_tree_view(layout)
            end

            def setup_filter_gui_elements(layout)
                # Filters on type
                @btn_display_compositions = Qt::CheckBox.new("Compositions", self)
                btn_display_compositions.checked = true
                btn_display_compositions.connect(SIGNAL('stateChanged(int)')) do |state|
                    update_model_filter
                end
                layout.add_widget(btn_display_compositions)
                @btn_display_task_contexts = Qt::CheckBox.new("Task Contexts", self)
                btn_display_task_contexts.checked = true
                btn_display_task_contexts.connect(SIGNAL('stateChanged(int)')) do |state|
                    update_model_filter
                end
                layout.add_widget(btn_display_task_contexts)
                @btn_display_data_services = Qt::CheckBox.new("Data Services", self)
                btn_display_data_services.checked = true
                btn_display_data_services.connect(SIGNAL('stateChanged(int)')) do |state|
                    update_model_filter
                end
                layout.add_widget(btn_display_data_services)
                @btn_display_profiles = Qt::CheckBox.new("Profiles", self)
                btn_display_profiles.checked = true
                btn_display_profiles.connect(SIGNAL('stateChanged(int)')) do |state|
                    update_model_filter
                end
                layout.add_widget(btn_display_profiles)
            end

            def syskit_model?(mod)
                mod.kind_of?(Syskit::Actions::Profile) ||
                    mod.kind_of?(Syskit::Models::DataServiceModel) ||
                    (mod.kind_of?(Class) && mod <= Syskit::Component)
            end

            def setup_tree_view(layout)
                @model_list = Qt::TreeView.new(self)
                @model_filter = Qt::SortFilterProxyModel.new
                model_filter.dynamic_sort_filter = true
                model_list.model = model_filter
                layout.add_widget(model_list)

                model_list.selection_model.connect(SIGNAL('currentChanged(const QModelIndex&, const QModelIndex&)')) do |index, _|
                    index = model_filter.map_to_source(index)
                    mod = browser_model.info_from_index(index)
                    if syskit_model?(mod.this)
                        emit model_selected(Qt::Variant.from_ruby(mod.this, mod.this))
                    end
                end

                reload
            end
            signals 'model_selected(QVariant)'

            def update_model_filter
                rx = []
                if btn_display_compositions.checked?
                    rx << 'Composition'
                end
                if btn_display_task_contexts.checked?
                    rx << 'TaskContext'
                end
                if btn_display_data_services.checked?
                    rx << 'DataService'
                end
                if btn_display_profiles.checked?
                    rx << 'Profile'
                end
                model_filter.filter_role = Qt::UserRole # filter on class/module ancestry
                model_filter.filter_reg_exp = Qt::RegExp.new(rx.join("|"))
            end

            def reload
                if current = current_selection
                    current_module = current.this
                    current_path = []
                    while current
                        current_path.unshift current.name
                        current = current.parent
                    end
                end

                model_type_info = Hash[
                    Syskit::Composition => RubyModuleModel::TypeInfo.new('Composition', 1),
                    Syskit::TaskContext => RubyModuleModel::TypeInfo.new('TaskContext', 1),
                    Syskit::DataService => RubyModuleModel::TypeInfo.new('DataService', 0),
                    Syskit::Actions::Profile => RubyModuleModel::TypeInfo.new('Profile', 1)
                ]
                @browser_model = RubyModuleModel.new(model_type_info) do |mod|
                    syskit_model?(mod)
                end
                model_filter.source_model = browser_model

                if current_path && !select_by_path(*current_path)
                    select_by_module(current_module)
                end
            end

            # Selects the current model given a path in the constant names
            # This emits the model_selected signal
            #
            # @return [Boolean] true if the path resolved to something known,
            #   and false otherwise
            def select_by_path(*path)
                if index = browser_model.find_index_by_path(*path)
                    index = model_filter.map_from_source(index)
                    model_list.selection_model.set_current_index(index, Qt::ItemSelectionModel::ClearAndSelect)
                    true
                end
            end

            # Selects the given model if it registered in the model list
            # This emits the model_selected signal
            #
            # @return [Boolean] true if the path resolved to something known,
            #   and false otherwise
            def select_by_module(model)
                if index = browser_model.find_index_by_model(model)
                    index = model_filter.map_from_source(index)
                    model_list.selection_model.set_current_index(index, Qt::ItemSelectionModel::ClearAndSelect)
                    true
                end
            end

            # Returns the currently selected item
            # @return [RubyModuleModel::ModuleInfo,nil] nil if there are no
            #   selections
            def current_selection
                index = model_list.selection_model.current_index
                if index.valid?
                    index = model_filter.map_to_source(index)
                    browser_model.info_from_index(index)
                end
            end
        end
    end
end
