module Ui
    # Widget used to display a network of Orocos tasks represented in a Roby
    # plan
    #
    # The technique used here is to convert the network to dot and then svg
    # using Orocos::RobyPlugin::Graphviz. The SVG is then postprocessed to allow
    # the creation of an association between graphical elements (identified
    # through their SVG object ID) and the graphical representation.
    class PlanDisplay < Qt::Object
        module GraphicsViewExtension
            attr_accessor :plan_display
            attribute(:current_scaling) { 1 }

            def mousePressEvent(event)
                items = self.items(event.pos)
                items = items.find_all do |i|
                    i.respond_to?(:real_object) &&
                        i.real_object
                end
                if sel = items.first
                    emit plan_display.
                        selectedObject(Qt::Variant.fromValue(sel.real_object))
                end
                event.accept
            end

            def wheelEvent(event)
                if event.modifiers != Qt::ControlModifier
                    return super
                end

                # See documentation of wheelEvent
                degrees = event.delta / 8.0
                num_steps = degrees / 15

                old = self.current_scaling
                new = old + num_steps
                if new == 0
                    if old > 0
                        @current_scaling = -1
                    else
                        @current_scaling = 1
                    end
                else
                    @current_scaling = new
                end
                scale_factor =
                    if current_scaling > 0
                        current_scaling
                    else
                        1.0 / current_scaling.abs
                    end

                self.transform = Qt::Transform.from_scale(scale_factor, scale_factor)

                event.accept
            end
        end

        # The GraphicsScene instance in which we actually generate a display
        attr_reader :scene
        # The GraphicsView widget that handles the scene
        attr_reader :view
        # A mapping from task objects to their SVG ID
        attr_reader :ruby_id_to_index
        # A mapping from task objects to their SVG ID
        attr_reader :svg_id_to_index
        attr_reader :index_to_object
        # The SVG renderer objects used to render the task SVGs
        attr_reader :renderers

        # The raw SVG data
        attr_reader :svg

        def show; view.show end

        def initialize(main = nil)
            super()
            @scene           = Qt::GraphicsScene.new
            @view            = Qt::GraphicsView.new(scene, main)
            @view.extend GraphicsViewExtension
            @view.plan_display = self
            @renderers       = Hash.new
            @svg             = Hash.new
            @index_to_object = Array.new
            @svg_id_to_index  = Hash.new
            @ruby_id_to_index  = Hash.new
            @stack = Array.new
            @title_font = Qt::Font.new
            title_font.bold = true

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        attr_reader :error_text
        attr_reader :stack
        attr_accessor :title_font

        def render_plan(mode, plan, engine, options)
            default_exclude = []
            if defined? Orocos::RobyPlugin::Logger::Logger
                default_exclude << Orocos::RobyPlugin::Logger::Logger
            end

            svg_io = Tempfile.open(mode)
            engine.to_svg(mode, svg_io, options)

            plan.each_task do |task|
                index = index_to_object.size
                index_to_object.push(task)
                ruby_id_to_index[task.object_id] = index
            end
            svg_io.rewind
            renderer, items = display_svg(svg_io)
            items

        ensure
            svg_io.close if svg_io
        end

        def clear
            renderers.clear
            stack.clear
            scene.clear
            svg.clear
            index_to_object.clear
            ruby_id_to_index.clear
            svg_id_to_index.clear
        end

        def push(title, item)
            if item.respond_to?(:to_ary)
                item = item.map do |w|
                    if w.kind_of?(Qt::Widget)
                        scene.add_widget(w)
                    else
                        w
                    end
                end
                item = scene.create_item_group(item)
            elsif item.kind_of?(Qt::Widget)
                item = scene.add_widget(item)
            end
            if !item.kind_of?(Qt::GraphicsItem)
                raise ArgumentError, "expected a graphics item but got #{item}"
            end
            stack.push([title, item])
        end

        def push_plan(title, mode, plan, engine, display_options)
            push(title, render_plan(mode, plan, engine, display_options))
        end

        TITLE_BOTTOM_MARGIN = 10
        SEPARATION_MARGIN = 50

        def update_view(plan, engine, display_options = Hash.new)
            clear
            push_plan('Task Dependency Hierarchy', 'hierarchy', plan, engine, display_options)
            push_plan('Dataflow', 'dataflow', plan, engine, display_options)
            render
        end

        def render
            y = 0
            stack.each do |title, item|
                title_item = scene.add_simple_text(title, title_font)
                title_item.move_by(0, y)
                y += title_item.bounding_rect.height + TITLE_BOTTOM_MARGIN

                item.move_by(0, y)
                y += item.bounding_rect.height + SEPARATION_MARGIN
            end
        end

        def display_error(message, error)
            # Then display the error as a text item above the rest
            if !@error_text
                # Set the opacity of all plan items to 0.2
                hierarchy_items.each do |it|
                    it.opacity = 0.2
                end
                dataflow_items.each do |it|
                    it.opacity = 0.2
                end

                @error_text = Qt::GraphicsTextItem.new
                scene.add_item(error_text)
            end
            error_text.plain_text = message + "\n\n" + Roby.format_exception(error).join("\n") + "\n" + error.backtrace.join("\n")
            error_text.default_text_color = Qt::Color.new('red')
        end

        module SvgObjectMapper
            attr_accessor :plan_display
            def real_object
                id = data(Qt::UserRole)
                if id.valid?
                    id = id.to_int
                    plan_display.index_to_object[id]
                end
            end
        end

        def display_svg(io)
            # Build a two-way mapping from the SVG IDs and the task objects
            svg_objects = Set.new

            if !io.respond_to?(:read)
                path = io
                svg_data = File.read(io)
            else
                path = io.path
                svg_data = io.read
            end

            svg[path.gsub(/\.svg$/, '')] = svg_data = svg_data.dup
            xml = Nokogiri::XML(svg_data)
            xml.children.children.children.each do |el|
                title = (el/"title")
                next if title.empty?

                id = title[0].content
                if id =~ /^(?:inputs|outputs|label)?(\d+)$/ # this node is a part of a task / composition
                    id = $1
                    index = ruby_id_to_index[Integer(id)]
                    svg_id_to_index[el['id']] = index
                end
                svg_objects << el['id']
            end

            renderer = (@renderers[path]  = Qt::SvgRenderer.new(Qt::ByteArray.new(svg_data)))

            all_items = []

            # Now, add separate graphics items for each of the tasks, so that we
            # are able to interact with them
            svg_objects.each do |svgid|
                pos = renderer.matrixForElement(svgid).
                    map(renderer.bounds_on_element(svgid).top_left)

                item = Qt::GraphicsSvgItem.new
                all_items << item

                item.shared_renderer = renderer
                item.element_id = svgid
                item.pos = pos
                if index = svg_id_to_index[svgid]
                    item.set_data(Qt::UserRole, Qt::Variant.new(index))
                end
                item.extend SvgObjectMapper
                item.plan_display = self
                scene.add_item(item)
            end

            view.update
            return renderer, all_items
        end

        signals 'selectedObject(QVariant&)'

        # The margin between the top and bottom parts of the saved SVG, in
        # points
        SVG_PARTS_MARGIN = 20

        def save_svg(filename)
            hierarchy = svg['hierarchy']
            dataflow  = svg['dataflow']

            # Generate one single SVG with both graphs
            hierarchy = Nokogiri::XML(hierarchy)
            dataflow  = Nokogiri::XML(dataflow)
            hierarchy_root = (hierarchy / 'svg').first
            hierarchy_view = hierarchy_root["viewBox"].split.map(&method(:Float))

            dataflow_root  = (dataflow / 'svg').first
            dataflow_view  = dataflow_root["viewBox"].split.map(&method(:Float))

            # Add a new group to hierarchy_root
            new_group = Nokogiri::XML::Node.new("g", hierarchy)
            hierarchy_root.add_child(new_group)
            new_group['transform'] = "translate(0, #{hierarchy_view[3] + SVG_PARTS_MARGIN})"
            new_group.add_child((dataflow_root / "g[id=graph1]").first.to_xml)

            # Update the lower bound for the view
            height = Float(hierarchy_root['height'].gsub('pt', ''))
            hierarchy_root['height'] = "#{height + dataflow_view[3] + SVG_PARTS_MARGIN}pt"
            hierarchy_view[3] += dataflow_view[3] + SVG_PARTS_MARGIN
            hierarchy_root['viewBox'] = hierarchy_view.map(&:to_s).join(" ")

            File.open(filename, 'w') do |io|
                io.write hierarchy_root.to_xml
            end
        end
    end
end
