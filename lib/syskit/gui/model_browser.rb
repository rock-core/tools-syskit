require 'metaruby/gui'
require 'syskit/gui/model_views'
require 'syskit/gui/page'
module Syskit
    module GUI
        class ModelBrowser < MetaRuby::GUI::ModelBrowser
            def initialize(parent = nil)
                super

                # Composition and task context must have a higher priority than
                # data services, as task contexts also have DataService in their
                # ancestry
                self.page = Page.new(display)
                register_type(Syskit::TaskContext, ModelViews::TaskContext, 'Task Contexts', 1)
                register_type(Syskit::Composition, ModelViews::Composition, 'Compositions', 1)
                register_type(Syskit::DataService, ModelViews::DataService, 'Data Services')
                register_type(Syskit::Actions::Profile, ModelViews::Profile, 'Profiles')
                register_type(Typelib::Type, ModelViews::Type, 'Types')

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

