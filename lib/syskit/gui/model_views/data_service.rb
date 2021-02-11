# frozen_string_literal: true

module Syskit::GUI
    module ModelViews
        class DataService < Component
            def initialize(page)
                super(page)
                buttons = []
                buttons.concat(self.class.common_graph_buttons("interface"))
                interface_options[:buttons] = buttons
            end

            def list_services(task)
                services = super
                services.first.last.shift
                if services.first.last.empty?
                    []
                else
                    services
                end
            end

            def render(model, options = {})
                super

                providers = []
                Syskit::TaskContext.each_submodel do |component_m|
                    next if component_m.placeholder?

                    if component_m.fullfills?(model)
                        providers << [component_m.name, component_m]
                    end
                end
                Syskit::Composition.each_submodel do |composition_m|
                    next if composition_m.placeholder?
                    next if composition_m.is_specialization?

                    if composition_m.fullfills?(model)
                        providers << [composition_m.name, composition_m]
                    else
                        composition_m.specializations.each_specialization do |spec|
                            if spec.composition_model.fullfills?(model)
                                providers << [spec.to_s, composition_m.root_model]
                            end
                        end
                    end
                end

                providers = providers.sort_by(&:first)
                                     .map do |name, model|
                    page.link_to(model, name)
                end
                page.render_list("Provided By", providers)
            end

            def render_data_services(task, with_names = false)
                super
            end
        end
    end
end
