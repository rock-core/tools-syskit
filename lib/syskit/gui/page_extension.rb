# frozen_string_literal: true

module Syskit
    module GUI
        module PageExtension
            # Returns the path part of the URI to an object
            #
            # Overloaded from MetaRuby to handle task contexts properly in the
            # oroGen HTML templates. In these templates, the models are
            # OroGen::Spec::TaskContext, but the model browser only knows about
            # Syskit::TaskContext
            def uri_for(object)
                if object.kind_of?(OroGen::Spec::TaskContext)
                    if syskit_model = Syskit::TaskContext.find_model_by_orogen(object)
                        super(syskit_model)
                    end
                else
                    super
                end
            end

            # Adds a plan representation on the page
            #
            # @param [String] title the title that should be added to the
            #   section
            # @param [String] kind either dataflow or hierarchy
            # @param [Roby::Plan] plan
            # @param [Array] buttons a list of [MetaRuby::GUI::HTML::Button] to
            #   be rendered on top of the plan to interact with it
            # @param [Float] zoom the zooming factor for the rendered SVG
            # @param [String] id the fragment id
            # @param [String] external_objects if given, the rendered SVG is
            #   saved in a file whose name is generated using #{external_objects % kind}.svg
            # @param [Hash] options additional options to pass to
            #   {Graphviz#to_file}
            def push_plan(title, kind, plan, buttons: [],
                zoom: 1, id: kind, external_objects: nil,
                **options)

                svg_io = Tempfile.open(kind)
                begin
                    Syskit::Graphviz.new(plan, self, typelib_resolver: GUI::ModelBrowser::TypelibResolver.new)
                                    .to_file(kind, "svg", svg_io, options)
                    svg_io.flush
                    svg_io.rewind
                    svg = svg_io.read
                    svg = svg.encode "utf-8", invalid: :replace
                rescue DotCrashError, DotFailedError => e
                    svg = e.message
                end

                # Fixup a mixup in dot's SVG output. The URIs that contain < and >
                # are not properly escaped to &lt; and &gt;
                svg = svg.gsub(/xlink:href="[^"]+"/) { |match| match.gsub("<", "&lt;").gsub(">", "&gt;") }

                begin
                    if match = /svg width=\"(\d+)(\w+)\" height=\"(\d+)(\w+)\"/.match(svg)
                        width, w_unit, height, h_unit = *match.captures
                        svg = match.pre_match + "svg width=\"#{(Float(width) * zoom * 0.6)}#{w_unit}\" height=\"#{(Float(height) * zoom * 0.6)}#{h_unit}\"" + match.post_match
                    end
                rescue ArgumentError
                end

                if pattern = external_objects
                    file = pattern % kind + ".svg"
                    File.open(file, "w") do |io|
                        io.write(svg)
                    end
                    push(title, "<object data=\"#{file}\" type=\"image/svg+xml\"></object>",
                         id: id, buttons: buttons)
                else
                    push(title, svg, id: id, buttons: buttons)
                end
                emit :updated
            end
        end
    end
end
