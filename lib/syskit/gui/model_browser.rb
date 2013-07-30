require 'metaruby/gui'
require 'syskit/gui/model_views'
require 'syskit/gui/page'
require 'roby/gui/model_views'
module Syskit
    module GUI
        class ModelBrowser < MetaRuby::GUI::ModelBrowser
            View = Struct.new :root_model, :renderer, :name, :priority
            AVAILABLE_VIEWS = [
                View.new(Syskit::TaskContext, ModelViews::TaskContext, 'Task Contexts', 1),
                View.new(Syskit::Composition, ModelViews::Composition, 'Compositions', 1),
                View.new(Syskit::DataService, ModelViews::DataService, 'Data Services', 0),
                View.new(Syskit::Actions::Profile, ModelViews::Profile, 'Profiles', 0),
                View.new(Roby::Actions::Interface, Roby::GUI::ModelViews::ActionInterface, 'Action Interfaces', 0),
                View.new(Typelib::Type, ModelViews::Type, 'Types', 0)
            ]

            def initialize(parent = nil)
                super

                self.page = Page.new(display)
                AVAILABLE_VIEWS.each do |view|
                    register_type(view.root_model, view.renderer, view.name, view.priority)
                end

                btn_reload_models.connect(SIGNAL('clicked()')) do
                    registered_exceptions.clear
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    update_exceptions
                    model_selector.reload
                end
            end

            def registered_exceptions
                super + Roby.app.registered_exceptions
            end
        end
    end
end

