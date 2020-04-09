# frozen_string_literal: true

require "syskit/gui/model_browser"
module Syskit
    module GUI
        # Main widget for model browsing
        class Browse < Qt::Widget
            # The widget's main layout
            #
            # @return [Qt::Layout]
            attr_reader :main_layout

            # The button that triggers model reloading
            #
            # @return [Qt::PushButton]
            attr_reader :btn_reload_models

            # The model browser object
            #
            # @return [ModelBrowser]
            attr_reader :model_browser

            def initialize(parent = nil)
                super
                @main_layout = Qt::VBoxLayout.new(self)

                @model_browser = ModelBrowser.new(self)
                @btn_reload_models = Qt::PushButton.new("Reload Models", self)

                main_layout.add_widget btn_reload_models
                main_layout.add_widget model_browser

                btn_reload_models.connect(SIGNAL("clicked()")) do
                    model_browser.registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    model_browser.update_exceptions
                    model_browser.reload
                end
            end

            # Select the current model using its module
            def select_by_model(mod)
                model_browser.select_by_model(mod)
            end
        end
    end
end
