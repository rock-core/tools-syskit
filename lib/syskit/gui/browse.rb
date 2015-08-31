require 'syskit/gui/model_browser'
module Syskit
    module GUI
        class Browse < Qt::Widget
            attr_reader :main_layout
            attr_reader :btn_reload_models
            attr_reader :model_browser

            def initialize(parent = nil)
                super
                @main_layout = Qt::VBoxLayout.new(self)

                @model_browser = ModelBrowser.new(self)
                @btn_reload_models = Qt::PushButton.new("Reload Models", self)

                main_layout.add_widget btn_reload_models
                main_layout.add_widget model_browser

                btn_reload_models.connect(SIGNAL('clicked()')) do
                    model_browser.registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    model_browser.update_exceptions
                    model_browser.reload
                end

                model_browser
            end

            def select_by_module(mod)
                model_browser.select_by_module(mod)
            end
        end
    end
end

