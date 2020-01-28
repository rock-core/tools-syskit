# frozen_string_literal: true

require 'utilrb/qt/variant/from_ruby'
require 'syskit/gui/component_network_view'

module Syskit::GUI
    module ModelViews
        def self.render_selection_mapping(page, mapping)
            mapping.map do |key, sel|
                render_mapping(page, key, sel)
            end
        end

        def self.render_mapping(page, key, sel)
            key =
                if key.respond_to?(:to_instance_requirements)
                    render_instance_requirements(page, key.to_instance_requirements)
                else
                    [key.to_s]
                end

            sel =
                if sel.respond_to?(:to_instance_requirements)
                    render_instance_requirements(page, sel.to_instance_requirements)
                else
                    [sel.to_s]
                end

            longest_key_line = key.max_by(&:size).size
            key += [' ' * longest_key_line] * (sel.size - key.size) if key.size < sel.size
            key.each_with_index.map do |k, key_index|
                if (v = sel[key_index])
                    k += ' ' * (longest_key_line - k.size)
                    k += ': ' if key_index == 0
                    k + v.to_s
                else
                    k
                end
            end
        end

        def self.render_instance_requirements_selections(
            page, selections, use_method = 'use'
        )
            defaults = selections.defaults.map do |defsel|
                render_instance_requirements(page, defsel.to_instance_requirements)
            end
            explicit = render_selection_mapping(page, selections.explicit)
            all = defaults + explicit
            all = all.each_with_index.map do |block, i|
                block[0] = (i == 0 ? "  #{use_method}(" : '      ') + block[0]
                block = [block[0]] + block[1..-1].map do |line|
                    '      ' + line
                end
                block[-1] = block[-1] + (i == all.size - 1 ? ')' : ',')
                block
            end.flatten
        end

        def self.render_instance_requirements(
            page, req, resolve_dependency_injection: false
        )
            # First, render the main model
            component_model = [req.component_model]
            req_component = req.to_component_model

            component_model.pop unless component_model.first # This is a service proxy

            if req.model.respond_to?(:tag_name)
                tag_name = req.model.tag_name
                formatted = [
                    "<a href=\"#tag_definition_#{tag_name}\">#{tag_name}_tag</a>"
                ]
            else
                if req_component.model.placeholder?
                    service_models = req_component
                                     .model
                                     .proxied_data_service_models
                                     .sort_by(&:name).compact
                    component_model.concat(service_models)
                end
                formatted = [component_model.map { |m| page.link_to(m) }.join(',')]
            end
            unless req.arguments.empty?
                arguments = req.arguments.map { |key, value| "#{key}: #{value}" }
                arguments = MetaRuby::GUI::HTML.escape_html(arguments.join(', '))
                formatted[0] += ".with_arguments(#{arguments})"
            end

            if resolve_dependency_injection
                selections = req.resolved_dependency_injection
                unless selections.empty?
                    formatted_selections = render_instance_requirements_selections(
                        page, selections
                    )
                    formatted[-1] += '.'
                    formatted.concat formatted_selections
                end
            else
                pushed_selections = req.send(:pushed_selections)
                unless pushed_selections.empty?
                    formatted_selections = render_instance_requirements_selections(
                        page, pushed_selections, 'use<0>'
                    )
                    formatted[-1] += '.'
                    formatted.concat formatted_selections
                    use_suffix = '<1>'
                end

                selections = req.send(:selections)
                unless selections.empty?
                    formatted_selections = render_instance_requirements_selections(
                        page, selections, "use#{use_suffix}"
                    )
                    formatted[-1] += '.'
                    formatted.concat formatted_selections
                end
            end
            formatted
        end

        class ProfileElementView < ComponentNetworkView
            def render(model, *args, **options)
                page.push "#{model.name || '<unnamed>'}(#{model.model.name})",
                          page.main_doc(model.doc || ''), id: options[:id]
                super
            end
        end

        # Visualization of a syskit profile
        class Profile < MetaRuby::GUI::HTML::Collection
            attr_accessor :instanciation_method

            def initialize(page)
                super(page)
                @instanciation_method = :compute_system_network

                register_type Syskit::InstanceRequirements, ProfileElementView.new(page),
                              method: :compute_system_network, show_requirements: true
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
                        key_text, value_text = text.first.split(': ')
                        text[0] = "%s: #{value_text}"
                        Element.new(object, "<pre>#{text.join("\n")}</pre>",
                                    id, key_text, { buttons: [] }, {})
                    else
                        Element.new(object, '%s', id, key, { buttons: [] }, {})
                    end
                end
            end

            def first_paragraph(string)
                paragraph = ''.dup
                string.each_line do |line|
                    line = line.chomp
                    return paragraph if line.empty?

                    paragraph << ' ' << line
                end
                paragraph
            end

            def compute_toplevel_links(model, options)
                explicit_selections = mapping_to_links(
                    model.dependency_injection.explicit,
                    true, options[:interactive]
                )

                defaults = model.dependency_injection.defaults
                                .each_with_object({}) { |k, h| h[k] = k }
                default_selections = mapping_to_links(
                    defaults, false, options[:interactive]
                )

                definitions = {}
                model.definitions.keys.sort.each do |name|
                    definitions[name] = model.resolved_definition(name)
                end
                definitions = mapping_to_links(definitions, false, options[:interactive])
                definitions.each do |obj|
                    doc = first_paragraph(obj.object.doc || '')
                    obj.format = "%s: #{doc}"
                end

                devices = {}
                model.robot.each_device.sort_by(&:name).each do |dev|
                    req = dev.to_instance_requirements
                    model.inject_di_context(req)
                    devices[dev.name] = req
                end
                devices = mapping_to_links(devices, false, options[:interactive])

                [explicit_selections, default_selections, definitions, devices]
                    .each do |collection|
                        collection.each do |el|
                            el.object = el.object.to_instance_requirements
                            el.rendering_options[:method] = instanciation_method
                        end
                    end

                [explicit_selections, default_selections, definitions, devices]
            end

            def render(model, interactive: true, **push_options)
                explicit_selections, default_selections, definitions, devices =
                    compute_toplevel_links(model, interactive: interactive)

                ComponentNetworkBaseView.html_defined_in(page, model, with_require: true)
                render_links('Explicit Selection', explicit_selections)
                render_links('Default selections', default_selections)
                render_links('Definitions', definitions)
                render_links('Devices', devices)
                page.save

                return if interactive

                render_all_elements(
                    explicit_selections + default_selections + definitions + devices,
                    interactive: false, **push_options
                )
            end
        end
    end
end
