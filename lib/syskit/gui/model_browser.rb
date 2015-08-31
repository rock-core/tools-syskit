require 'syskit'
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
                View.new(Roby::Task, Roby::GUI::ModelViews::Task, 'Roby Tasks', 0),
                View.new(Typelib::Type, ModelViews::Type, 'Types', 0)
            ]

            def initialize(parent = nil)
                super

                if ENV['SYSKIT_GUI_DEBUG_HTML']
                    display.page.settings.setAttribute(Qt::WebSettings::DeveloperExtrasEnabled, true)
                    @inspector = Qt::WebInspector.new
                    @inspector.page = display.page
                    @inspector.show
                end

                page.load_javascript File.expand_path("composer_buttons.js", File.dirname(__FILE__))
                AVAILABLE_VIEWS.each do |view|
                    register_type(view.root_model, view.renderer, view.name, view.priority)
                end
                update_model_selector
            end

            def registered_exceptions
                super + Roby.app.registered_exceptions
            end
        end
    end
end

