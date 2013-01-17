require 'syskit/gui/ruby_module_model'
module Syskit
    module GUI
        class ModelSelector < Qt::Widget
            attr_reader :btn_display_compositions
            attr_reader :btn_display_data_services
            attr_reader :btn_display_task_contexts
            attr_reader :model_filter

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
            end

            def syskit_model?(mod)
                mod.kind_of?(Syskit::Models::DataServiceModel) ||
                    (mod.kind_of?(Class) && mod <= Syskit::Component)
            end

            def setup_tree_view(layout)
                model_list = Qt::TreeView.new(self)
                model_type_info = Hash[
                    Syskit::Composition => RubyModuleModel::TypeInfo.new('Composition', 1),
                    Syskit::TaskContext => RubyModuleModel::TypeInfo.new('TaskContext', 1),
                    Syskit::DataService => RubyModuleModel::TypeInfo.new('DataService', 0)
                ]
                browser_model = RubyModuleModel.new(model_type_info) do |mod|
                    syskit_model?(mod)
                end

                @model_filter = Qt::SortFilterProxyModel.new
                model_filter.source_model = browser_model
                model_list.model = model_filter
                layout.add_widget(model_list)

                model_list.connect(SIGNAL('clicked(const QModelIndex&)')) do |index|
                    index = model_filter.map_to_source(index)
                    mod = browser_model.info_from_index(index)
                    if syskit_model?(mod.this)
                        emit model_selected(Qt::Variant.from_ruby(mod.this, mod.this))
                    end
                end
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
                model_filter.filter_role = Qt::UserRole # filter on class/module ancestry
                model_filter.filter_reg_exp = Qt::RegExp.new(rx.join("|"))
            end

        end
    end
end
