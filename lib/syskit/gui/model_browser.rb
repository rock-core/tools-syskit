require 'syskit/gui/model_selector'
require 'syskit/gui/model_views'
require 'syskit/gui/exception_view'
require 'syskit/gui/html/page'
module Syskit
    module GUI
        # Widget that allows to browse the currently available models and
        # display information about them
        class ModelBrowser < Qt::Widget
            # Visualization and selection of models in the Ruby constant
            # hierarchy
            attr_reader :model_selector
            attr_reader :lbl_model_name
            attr_reader :exception_view

            def initialize(main = nil)
                super

                main_layout = Qt::VBoxLayout.new(self)

                menu_layout = Qt::HBoxLayout.new
                main_layout.add_layout(menu_layout)
                central_layout = Qt::HBoxLayout.new
                main_layout.add_layout(central_layout, 3)
                splitter = Qt::Splitter.new(self)
                central_layout.add_widget(splitter)
                @exception_view = ExceptionView.new
                main_layout.add_widget(exception_view, 1)


                btn_reload_models = Qt::PushButton.new("Reload", self)
                menu_layout.add_widget(btn_reload_models)
                btn_reload_models.connect(SIGNAL(:clicked)) do
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    update_exceptions
                    model_selector.reload
                end
                menu_layout.add_stretch(1)
                update_exceptions

                add_central_widgets(splitter)
            end

            def add_central_widgets(splitter)
                @model_selector = ModelSelector.new
                splitter.add_widget(model_selector)

                # Create a central stacked layout
                display = Qt::WebView.new
                splitter.add_widget(display)
                splitter.set_stretch_factor(1, 2)
                page = HTML::Page.new(display)

                renderers = Hash[
                    Syskit::Models::TaskContext => ModelViews::TaskContext.new(page),
                    Syskit::Models::Composition => ModelViews::Composition.new(page),
                    Syskit::Models::DataServiceModel => ModelViews::DataService.new(page),
                    Syskit::Actions::Profile => ModelViews::Profile.new(page)]

                model_selector.connect(SIGNAL('model_selected(QVariant)')) do |mod|
                    mod = mod.to_ruby
                    model, render = renderers.find do |model, render|
                        mod.kind_of?(model)
                    end
                    if model
                        title = "#{mod.name} (#{model.name})"
                        begin
                            page.clear
                            page.title = title
                            render.clear
                            render.render(mod)
                        rescue ::Exception => e
                            Roby.app.register_exception(e, "while rendering #{mod}")
                            update_exceptions
                        end
                    else
                        Kernel.raise ArgumentError, "no view available for #{mod.class} (#{mod})"
                    end
                end
            end

            def update_exceptions
                exception_view.exceptions = Roby.app.registered_exceptions
            end

            # (see ModelSelector#select_by_module)
            def select_by_path(*path)
                model_selector.select_by_path(*path)
            end

            # (see ModelSelector#select_by_module)
            def select_by_module(model)
                model_selector.select_by_module(model)
            end

            # (see ModelSelector#current_selection)
            def current_selection
                model_selector.current_selection
            end
        end
    end
end
