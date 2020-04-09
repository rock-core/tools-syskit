# frozen_string_literal: true

require "syskit"
require "metaruby/gui"
require "syskit/gui/model_views"
require "syskit/gui/page"
require "roby/gui/model_views"
require "roby/gui/exception_view"
module Syskit
    module GUI
        class ModelBrowser < MetaRuby::GUI::ModelBrowser
            View = Struct.new :root_model, :renderer, :name, :priority, :resolver

            class TypelibResolver
                def split_name(obj)
                    if obj == Typelib::Type
                        ["Types"]
                    else
                        ["Types"] + Typelib.split_typename(obj.name)
                    end
                end

                def each_submodel(obj)
                    if obj == Typelib::Type
                        loader = Roby.app.default_loader
                        loader.registry.each do |type|
                            next if loader.m_type?(type)
                            next if type.null?
                            next if type <= Typelib::NumericType
                            next if type <= Typelib::ArrayType

                            yield(type)
                        end
                    end
                end
            end

            class OroGenResolver
                def split_name(model)
                    name = model.name
                    if name.start_with?("OroGen.")
                        name.split(".")
                    else
                        name.split("::")
                    end
                end

                def each_submodel(model)
                    if model == Syskit::TaskContext
                        model.each_submodel do |m|
                            excluded = (!m.name || m.private_specialization?)
                            yield(m, excluded)
                        end
                    end
                end
            end

            class RobyTaskModelResolver < MetaRuby::GUI::ModelHierarchy::Resolver
                def initialize
                    super(Roby::Task)
                end

                def each_submodel(model)
                    super do |m|
                        yield(m) if !m.respond_to?(:placeholder?) ||
                            !m.placeholder?
                    end
                end
            end

            AVAILABLE_VIEWS = [
                View.new(Syskit::RubyTaskContext, ModelViews::RubyTaskContext, "Ruby Task Contexts", 2),
                View.new(Syskit::TaskContext, ModelViews::TaskContext, "Task Contexts", 1, OroGenResolver.new),
                View.new(Syskit::Composition, ModelViews::Composition, "Compositions", 1),
                View.new(Syskit::DataService, ModelViews::DataService, "Data Services", 0),
                View.new(Syskit::Actions::Profile, ModelViews::Profile, "Profiles", 0),
                View.new(Roby::Actions::Interface, Roby::GUI::ModelViews::ActionInterface, "Action Interfaces", 0),
                View.new(Roby::Task, Roby::GUI::ModelViews::Task, "Roby Tasks", 0, RobyTaskModelResolver.new),
                View.new(Typelib::Type, ModelViews::Type, "Types", 0, TypelibResolver.new)
            ].freeze

            def initialize(parent = nil)
                super(parent, exception_view: Roby::GUI::ExceptionView.new)
                self.page = Page.new(@model_selector, display.page)

                if ENV["SYSKIT_GUI_DEBUG_HTML"]
                    display.page.settings.setAttribute(Qt::WebSettings::DeveloperExtrasEnabled, true)
                    @inspector = Qt::WebInspector.new
                    @inspector.page = display.page
                    @inspector.show
                end

                page.load_javascript File.expand_path("composer_buttons.js", File.dirname(__FILE__))
                AVAILABLE_VIEWS.each do |view|
                    resolver = view.resolver ||
                        MetaRuby::GUI::ModelHierarchy::Resolver.new(view.root_model)
                    register_type(view.root_model, view.renderer, view.name,
                                  view.priority, categories: [view.name],
                                                 resolver: resolver)
                end
                update_model_selector
            end

            def registered_exceptions
                super + Roby.app.registered_exceptions
            end
        end
    end
end
