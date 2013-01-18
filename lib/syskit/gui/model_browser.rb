require 'syskit/gui/model_selector'
require 'syskit/gui/task_context_view'
require 'syskit/gui/composition_view'
require 'syskit/gui/data_service_view'
module Syskit
    module GUI
        # Widget that allows to browse the currently available models and
        # display information about them
        class ModelBrowser < Qt::Widget
            attr_reader :module_tree
            attr_reader :model_display
            attr_reader :model_filter

            def initialize(main = nil)
                super

                main_layout = Qt::VBoxLayout.new(self)

                menu_layout = Qt::HBoxLayout.new
                main_layout.add_layout(menu_layout)
                menu_layout.add_stretch(1)

                layout = Qt::HBoxLayout.new
                main_layout.add_layout(layout)
                splitter = Qt::Splitter.new(self)
                layout.add_widget(splitter)

                model_list = ModelSelector.new(splitter)
                splitter.add_widget(model_list)

                btn_reload_models = Qt::PushButton.new("Reload", self)
                menu_layout.add_widget(btn_reload_models)
                btn_reload_models.connect(SIGNAL(:clicked)) do
                    Roby.app.reload_models
                    model_list.reload
                end

                views = Hash[
                    Syskit::Models::TaskContext => [TaskContextView],
                    Syskit::Models::Composition => [CompositionView],
                    Syskit::Models::DataServiceModel => [DataServiceView]]

                # Create a central stacked layout
                display_selector = Qt::StackedWidget.new(self)
                splitter.add_widget(display_selector)
                splitter.set_stretch_factor(1, 2)
                # Pre-create all the necessary display views
                views.each do |model, view|
                    view << display_selector.add_widget(view[0].new(splitter))
                end

                model_list.connect(SIGNAL('model_selected(QVariant)')) do |mod|
                    mod = mod.to_ruby
                    views.each do |model, view|
                        if mod.kind_of?(model)
                            display_selector.current_index = view[1]
                        end
                    end
                    display_selector.current_widget.render(mod)
                end
            end
        end
    end
end
