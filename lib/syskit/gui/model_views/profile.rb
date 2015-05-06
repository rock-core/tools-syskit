require 'utilrb/qt/variant/from_ruby'
require 'syskit/gui/component_network_view'
module Syskit::GUI
    module ModelViews
        def self.render_selection_mapping(page, mapping)
            mapping.each_with_index.map do |(key, sel), sel_index|
                render_mapping(page, key, sel)
            end
        end

        def self.render_mapping(page, key, sel)
            if key.respond_to?(:to_instance_requirements)
                key = render_instance_requirements(page, key.to_instance_requirements)
            else
                key = [key.to_s]
            end
            if sel.respond_to?(:to_instance_requirements)
                sel = render_instance_requirements(page, sel.to_instance_requirements)
            else
                sel = [sel.to_s]
            end
            longest_key_line = key.max { |l| l.size }.size
            if key.size < sel.size
                key += [" " * longest_key_line] * (sel.size - key.size)
            end
            key.each_with_index.map do |k, key_index|
                if v = sel[key_index]
                    k += " " * (longest_key_line - k.size)
                    if key_index == 0
                        k += " => #{v}"
                    else
                        k += "    #{v}"
                    end
                else
                    k
                end
            end
        end

        def self.render_instance_requirements_selections(page, selections, use_method = "use")
            defaults = selections.defaults.map do |defsel|
                render_instance_requirements(page, defsel.to_instance_requirements)
            end
            explicit = render_selection_mapping(page, selections.explicit)
            all = defaults + explicit
            all = all.each_with_index.map do |block, i|
                if i == 0
                    block[0] = "  use(" + block.first
                else
                    block[0] = "      " + block.first
                end
                block = [block[0]] + block[1..-1].map do |line|
                    line = "      " + line
                end
                if i == all.size - 1
                    block[-1] = block.last + ")"
                else
                    block[-1] = block.last + ","
                end
                block
            end.flatten
        end

        def self.render_instance_requirements(page, req, options = Hash.new)
            options = Kernel.validate_options options,
                :resolve_dependency_injection => false

            # First, render the main model
            component_model = [req.component_model]
            req_component = req.to_component_model

            if !component_model.first # This is a service proxy
                component_model.pop
            end
            if req.model.respond_to?(:tag_name)
                tag_name = req.model.tag_name
                formatted = ["<a href=\"#tag_definition_#{tag_name}\">#{tag_name}_tag</a>"]
            else
                if req_component.model.respond_to?(:proxied_data_services)
                    component_model.concat(req_component.model.proxied_data_services.sort_by(&:name).compact)
                end
                formatted = [component_model.map { |m| page.link_to(m) }.join(",")]
            end
            if !req.arguments.empty?
                arguments = req.arguments.map { |key, value| "#{key} => #{value}" }
                formatted[0] += ".with_arguments(#{MetaRuby::GUI::HTML.escape_html(arguments.join(", "))})"
            end

            if options[:resolve_dependency_injection]
                selections = req.resolved_dependency_injection
                if !selections.empty?
                    formatted_selections = render_instance_requirements_selections(page, selections)
                    formatted[-1] += "."
                    formatted.concat formatted_selections
                end
            else
                pushed_selections = req.send(:pushed_selections)
                if !pushed_selections.empty?
                    formatted_selections = render_instance_requirements_selections(page, pushed_selections, "use<0>")
                    formatted[-1] += "."
                    formatted.concat formatted_selections
                    use_suffix = "<1>"
                end

                selections = req.send(:selections)
                if !selections.empty?
                    formatted_selections = render_instance_requirements_selections(page, selections, "use#{use_suffix}")
                    formatted[-1] += "."
                    formatted.concat formatted_selections
                end
            end
            formatted
        end

        # Visualization of a syskit profile
        class Profile < MetaRuby::GUI::HTML::Collection
            attr_accessor :instanciation_method

            def initialize(page)
                super(page)
                @instanciation_method = :compute_system_network

                register_type Syskit::InstanceRequirements, ComponentNetworkView.new(page), :method => :compute_system_network, :show_requirements => true
            end

            def render_object_as_text(model)
                render_instance_requirements(model.to_instance_requirements).join("\n")
            end

            def mapping_to_links(mapping, with_value, interactive = true)
                mapping.keys.map do |key|
                    object = mapping[key]
                    id = element_link_target(object, interactive)

                    if with_value
                        text = ModelViews.render_mapping(page, key, object)
                        key_text, value_text = text.first.split(" => ")
                        text[0] = "%s => #{value_text}"
                        Element.new(object, "<pre>#{text.join("\n")}</pre>", id, key_text, Hash.new)
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
                model.definitions.keys.sort.each do |name|
                    definitions[name] = model.resolved_definition(name)
                end
                definitions = mapping_to_links(
                    definitions, false, options[:interactive])

                devices = Hash.new
                model.robot.each_device.sort_by(&:name).each do |dev|
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

                ComponentNetworkBaseView.html_defined_in(page, model, with_require: true)
                render_links("Explicit Selection", explicit_selections)
                render_links("Default selections", default_selections)
                render_links("Definitions", definitions)
                render_links("Devices", devices)
                page.save

                if !options[:interactive]
                    render_all_elements(explicit_selections + default_selections + definitions + devices, options.merge(push_options))
                end
            end
        end
    end
end

