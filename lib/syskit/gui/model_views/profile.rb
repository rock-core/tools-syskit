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
                "<div class=\"button_bar\"><em>#{title}:</em> #{links.map { |_, format, url, text| format % ["<a href=\"#{url}\">#{text}</a>"] }.join(" / ")}</div>"
            end

            def element_link_target(object, interactive)
                if interactive
                    id =  "btn://metaruby/profiles/#{object.object_id}"
                else
                    id =  "##{object.object_id}"
                end
            end

            def render_name_to_model_mapping(mapping, with_value, interactive = true)
                keys = mapping.keys.map do |key|
                    if !key.respond_to?(:to_str)
                        [key, html_model(key)]
                    else
                        [key, key]
                    end
                end

                links = keys.map do |key, key_text|
                    model = mapping[key]
                    id = element_link_target(model, interactive)
                    models[model.object_id] = model
                    if with_value
                        text = html_model(model)
                        [model, "#{key_text} => %s", id, text]
                    else
                        [model, "%s", id, key_text]
                    end
                end
            end

            def compute_toplevel_links(model, options)
                explicit_selections = render_name_to_model_mapping(
                    model.dependency_injection.explicit,
                    true, options[:interactive])

                default_selections = model.dependency_injection.defaults.map do |model|
                    text = html_model(model)
                    models[model.object_id] = model
                    [model, "%s", element_link_target(model), text]
                end

                definitions = Hash.new
                model.definitions.each_key do |name|
                    definitions[name] = model.resolved_definition(name)
                end
                definitions = render_name_to_model_mapping(
                    definitions, false, options[:interactive])

                devices = Hash.new
                model.robot.each_device do |dev|
                    req = dev.to_instance_requirements
                    model.inject_di_context(req)
                    devices[dev.name] = req
                end
                devices = render_name_to_model_mapping(
                    devices, false, options[:interactive])

                return explicit_selections, default_selections, definitions, devices
            end


            def render(model, options = Hash.new)
                options, push_options = Kernel.filter_options options, :interactive => true

                explicit_selections, default_selections, definitions, devices =
                    compute_toplevel_links(model, options)

                html = []
                if file = ComponentNetworkBaseView.find_definition_place(model)
                    html <<  "<p><b>Defined in</b> #{file[0]}:#{file[1]}</p>"
                end
                html << render_links("Explicit Selection", explicit_selections)
                html << render_links("Default selections", default_selections)
                html << render_links("Definitions", definitions)
                html << render_links("Devices", devices)
                page.push(nil, html.join("\n"))

                if !options[:interactive]
                    render_all_elements(explicit_selections + default_selections + definitions + devices, options.merge(push_options))
                end
            end

            def render_all_elements(all, options)
                all.each do |model, format, url, text|
                    page.push(nil, "<h1 id=#{model.object_id}>#{format % text}</h1>")

                    dataflow_options  = Hash[:id => "dataflow-#{model.object_id}"]
                    hierarchy_options = Hash[:id => "hierarchy-#{model.object_id}"]
                    if external_objects = options.delete(:external_objects)
                        model_file_suffix = (format % text).gsub(/[^\w]/, "_")
                        dataflow_options[:external_objects] = external_objects % "dataflow-#{model_file_suffix}"
                        hierarchy_options[:external_objects] = external_objects % "hierarchy-#{model_file_suffix}"
                    end

                    render_network(model,
                                   options.merge(:dataflow => dataflow_options, :hierarchy => hierarchy_options)
                                  )
                end
            end

            def linkClicked(url)
                if url.host == "metaruby" && url.path =~ /^\/profiles\/(\d+)/
                    model = models[Integer($1)]
                    render_network(model)
                end
            end
            slots 'linkClicked(const QUrl&)'

            def render_network(spec, options = Hash.new)
                return if spec.respond_to?(:to_str)
                spec = spec.to_instance_requirements
                network_renderer.render(spec, Hash[:method => instanciation_method].merge(options))
                emit updated
            rescue ::Exception => e
                Roby.app.register_exception(e)
                emit updated
            end

            signals :updated
        end
    end
end

