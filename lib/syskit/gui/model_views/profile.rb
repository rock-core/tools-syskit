require 'utilrb/qt/variant/from_ruby'
require 'syskit/gui/component_network_view'
module Syskit::GUI
    module ModelViews
        # Visualization of a syskit profile
        class Profile < MetaRuby::GUI::HTML::Collection
            attr_accessor :instanciation_method

            def initialize(page)
                super(page)
                @instanciation_method = :compute_system_network

                register_type Syskit::InstanceRequirements, ComponentNetworkView.new(page)
            end

            def render_object_as_text(model)
                value = model.to_instance_requirements
                if value.service
                    value.service.to_s
                else
                    value.model.to_s
                end
            end

            def mapping_to_links(mapping, with_value, interactive = true)
                mapping.keys.map do |key|
                    object = mapping[key]
                    id = element_link_target(object, interactive)

                    key_text =
                        if with_value
                            key.to_s
                        elsif key.respond_to?(:to_str) then key
                        else render_object_as_text(key)
                        end

                    if with_value
                        text = render_object_as_text(object)
                        Element.new(object, "#{key_text} => %s", id, text, Hash.new)
                    else
                        Element.new(object, "%s", id, key, Hash.new)
                    end
                end
            end


            def compute_toplevel_links(model, options)
                explicit_selections = mapping_to_links(
                    model.dependency_injection.explicit,
                    true, options[:interactive])

                defaults = model.dependency_injection.defaults.inject(Hash.new) do |h, k|
                    h[k] = k
                    h
                end
                default_selections = mapping_to_links(
                    defaults, false, options[:interactive])

                definitions = Hash.new
                model.definitions.each_key do |name|
                    definitions[name] = model.resolved_definition(name)
                end
                definitions = mapping_to_links(
                    definitions, false, options[:interactive])

                devices = Hash.new
                model.robot.each_device do |dev|
                    req = dev.to_instance_requirements
                    model.inject_di_context(req)
                    devices[dev.name] = req
                end
                devices = mapping_to_links(
                    devices, false, options[:interactive])

                [explicit_selections, default_selections, definitions, devices].each do |collection|
                    collection.each do |el|
                        el.object = el.object.to_instance_requirements
                        el.rendering_options[:method] = instanciation_method
                    end
                end

                return explicit_selections, default_selections, definitions, devices
            end

            def render(model, options = Hash.new)
                options, push_options = Kernel.filter_options options, :interactive => true

                explicit_selections, default_selections, definitions, devices =
                    compute_toplevel_links(model, options)

                if file = ComponentNetworkBaseView.find_definition_place(model)
                    page.push(nil, "<p><b>Defined in</b> #{file[0]}:#{file[1]}</p>")
                end
                render_links("Explicit Selection", explicit_selections)
                render_links("Default selections", default_selections)
                render_links("Definitions", definitions)
                render_links("Devices", devices)

                if !options[:interactive]
                    render_all_elements(explicit_selections + default_selections + definitions + devices, options.merge(push_options))
                end
            end
        end
    end
end

