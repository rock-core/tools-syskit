# frozen_string_literal: true

require "syskit/gui/model_browser"
require "syskit/gui/instanciate"
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
                @tabs = Qt::TabWidget.new(self)

                @btn_reload_models = Qt::PushButton.new("Reload Models", self)

                main_layout.add_widget btn_reload_models
                main_layout.add_widget @tabs

                btn_reload_models.connect(SIGNAL("clicked()")) do
                    model_browser.registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    model_browser.update_exceptions
                    model_browser.reload
                end

                add_model_browser
                add_instanciation
            end

            def add_model_browser
                @model_browser = ModelBrowser.new(self)
                @tabs.add_tab @model_browser, "Browse"
            end

            def add_instanciation
                @instanciate_gui = Instanciate.new(self)
                @tabs.add_tab @instanciate_gui, "Instanciate"
            end

            # Select the current model using its module
            def select_by_model(mod)
                model_browser.select_by_model(mod)
            end
        end
    end
end
