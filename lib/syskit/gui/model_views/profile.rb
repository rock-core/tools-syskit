require 'utilrb/qt/variant/from_ruby'
require 'syskit/gui/component_network_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a syskit profile
        class Profile < Qt::Object
            attr_reader :models
            attr_accessor :instanciation_method
            attr_reader :page
            attr_reader :network_renderer

            def initialize(page)
                super()
                @page = page
                @models = Hash.new
                @instanciation_method = :compute_system_network
                @network_renderer = ComponentNetworkView.new(page)
            end

            def enable
                connect(page, SIGNAL('linkClicked(const QUrl&)'), self, SLOT('linkClicked(const QUrl&)'))
                network_renderer.enable
            end
            def disable
                disconnect(page, SIGNAL('linkClicked(const QUrl&)'), self, SLOT('linkClicked(const QUrl&)'))
                network_renderer.disable
            end

            def clear
                network_renderer.clear
                @models.clear
            end

            def html_model(model)
                value = model.to_instance_requirements
                if value.service
                    value.service.to_s
                else
                    value.models.map(&:name).sort.join(",")
                end
            end

            def render_links(title, links)
                "<div class=\"button_bar\"><em>#{title}:</em> #{links.map { |format, url, text| format % ["<a href=\"btn://#{url}\">#{text}</a>"] }.join(" / ")}</div>"
            end

            def render_name_to_model_mapping(title, mapping, with_value)
                links = mapping.keys.sort_by { |v| if v.respond_to?(:to_str) then v else html_model(v) end }.map do |key|
                    model = mapping[key]
                    if !key.respond_to?(:to_str)
                        key = html_model(key)
                    end

                    id =  "metaruby/profiles/#{model.object_id}"
                    models[model.object_id] = model
                    if with_value
                        text = html_model(model)
                        ["#{key} => %s", id, text]
                    else
                        ["%s", id, key]
                    end
                end
                render_links(title, links)
            end

            def render(model, options = Hash.new)
                html = []
                if file = ComponentNetworkBaseView.find_definition_place(model)
                    html <<  "<p><b>Defined in</b> #{file[0]}:#{file[1]}</p>"
                end
                html << render_name_to_model_mapping("Explicit selections", model.dependency_injection.explicit, true)

                links = model.dependency_injection.defaults.map do |model|
                    text = html_model(model)
                    models[model.object_id] = model
                    ["%s", "metaruby/profiles/#{model.object_id}", text]
                end
                html << render_links("Default selections", links)

                definitions = Hash.new
                model.definitions.each_key do |name|
                    definitions[name] = model.resolved_definition(name)
                end
                html << render_name_to_model_mapping("Definitions", definitions, false)
                devices = Hash.new
                model.robot.each_device do |dev|
                    req = dev.to_instance_requirements
                    model.inject_di_context(req)
                    devices[dev.name] = req
                end
                html << render_name_to_model_mapping("Devices", devices, false)
                page.push(nil, html.join("\n"))
            end

            def linkClicked(url)
                if url.host == "metaruby" && url.path =~ /^\/profiles\/(\d+)/
                    model = models[Integer($1)]
                    render_network(model)
                end
            end
            slots 'linkClicked(const QUrl&)'

            def render_network(spec)
                return if spec.respond_to?(:to_str)
                spec = spec.to_instance_requirements
                network_renderer.render(spec, :method => instanciation_method)
                emit updated
            rescue ::Exception => e
                Roby.app.register_exception(e)
                emit updated
            end

            signals :updated
        end
    end
end

