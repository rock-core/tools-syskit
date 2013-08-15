module Syskit::GUI
    module ModelViews
        class DataService < Component
            def initialize(page)
                super(page)
                buttons = Array.new
                buttons.concat(self.class.common_graph_buttons('interface'))
                interface_options[:buttons] = buttons
            end

            def list_services(task)
                services = super
                services.first.last.shift
                if services.first.last.empty?
                    Array.new
                else
                    services
                end
            end

            def render(model, options = Hash.new)
                super

                providers = Array.new
                Syskit::Component.each_submodel do |component_m|
                    if component_m.fullfills?(model)
                        if component_m.permanent_model?
                            providers << [component_m.name, component_m]
                        elsif component_m.respond_to?(:is_specialization?)
                            providers << [component_m.name, component_m.root_model]
                        end
                    end
                end

                providers = providers.sort_by(&:first).
                    map do |name, model|
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
