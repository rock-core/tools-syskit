# frozen_string_literal: true

require "orogen/html"
module Syskit::GUI
    module ModelViews
        class Type < Qt::Object
            attr_reader :page
            attr_reader :type_rendering

            def initialize(page)
                super()
                @page = page
                @type_rendering = OroGen::HTML::Type.new(page)
            end

            def enable; end

            def disable; end

            def clear; end

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

            def render(type, options = {})
                type_rendering.render(type)

                producers = Set.new
                consumers = Set.new
                [Syskit::Component, Syskit::DataService].each do |base_model|
                    base_model.each_submodel do |submodel|
                        next if submodel.placeholder?

                        submodel.each_output_port do |port|
                            if port.type.name == type.name
                                producers << [page.link_to(submodel), port.name]
                            end
                        end
                        submodel.each_input_port do |port|
                            if port.type.name == type.name
                                consumers << [page.link_to(submodel), port.name]
                            end
                        end
                    end
                end

                fragment = render_port_list(producers.to_a.sort)
                page.push("Producers", fragment)
                fragment = render_port_list(consumers.to_a.sort)
                page.push("Consumers", fragment)
            end

            signals "updated()"
        end
    end
end
