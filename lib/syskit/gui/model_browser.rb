require 'syskit/gui/model_selector'
require 'syskit/gui/model_display_view'
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

                model_list.connect(SIGNAL('model_selected(QVariant)')) do |mod|
                    model_display.render_model(mod.to_ruby)
                end

                @model_display = ModelDisplayView.new(splitter)
                splitter.add_widget(model_display)
                splitter.set_stretch_factor(1, 2)
            end
        end
    end
end
