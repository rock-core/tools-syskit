require 'rock/doc'
require 'autoproj'
module Syskit::GUI
    module ModelViews
        module TypeRenderingExtension
            def link_to(arg)
                name = arg.name
                "<a href=\"model://syskit/types#{Rock::Doc::HTML.escape_html(name)}\">#{super}</a>"
            end
        end
        Rock::Doc::HTML::TypeRenderingContext.include TypeRenderingExtension

        class Type < Qt::Object
            attr_reader :page

            def initialize(page)
                super()
                @page = page
            end

            def enable
            end

            def disable
            end

            def clear
            end

            def render_port_list(content)
                template = <<-EOHTML
                <ul class="body-header-list">
                <% content.each do |model, port| %>
                <li><b><%= model %></b>.<%= port %>
                <% end %>
                </ul>
                EOHTML
                ERB.new(template).result(binding)
            end

            def render(type)
                fragment = Rock::Doc::HTML.render_object(type, 'type_fragment.page')
                page.push('Definition', fragment)

                producers, consumers = [], []
                [Syskit::Component,Syskit::DataService].each do |base_model|
                    base_model.each_submodel do |submodel|
                        submodel.each_output_port do |port|
                            if port.type.name == type.name
                                producers << [submodel.name, port.name]
                            end
                        end
                        submodel.each_input_port do |port|
                            if port.type.name == type.name
                                consumers << [submodel.name, port.name]
                            end
                        end
                    end
                end

                fragment = render_port_list(producers.sort)
                page.push('Producers', fragment)
                fragment = render_port_list(consumers.sort)
                page.push('Consumers', fragment)
            end
        end
    end
end
