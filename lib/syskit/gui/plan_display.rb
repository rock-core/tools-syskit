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
            attribute(:current_scaling) { 1 }

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
        attr_reader :task_from_id
        # A mapping from the SVG GraphicsItems to the task object
        attr_reader :graphicsitem_to_task
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
            @renderers       = Hash.new
            @svg             = Hash.new
            @svg_items = Hash.new
            @task_from_id = Hash.new
            @stack = Array.new
            @title_font = Qt::Font.new
            title_font.bold = true

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        attr_reader :svg_items
        attr_reader :error_text
        attr_reader :stack
        attr_accessor :title_font

        def render_plan(mode, plan, engine, display_options)
            default_exclude = []
            if defined? Orocos::RobyPlugin::Logger::Logger
                default_exclude << Orocos::RobyPlugin::Logger::Logger
            end

            display_options = Kernel.validate_options display_options,
                :remove_compositions => false,
                :excluded_tasks => default_exclude.to_value_set,
                :annotations => Set.new

            svg_io = Tempfile.open(mode)
            if mode == "dataflow"
                engine.to_svg(mode, svg_io, display_options[:remove_compositions],
                             display_options[:excluded_tasks],
                             display_options[:annotations])
            else
                engine.to_svg(mode, svg_io)
            end

            plan.each_task do |task|
                task_from_id[task.object_id] = task
            end
            if old_items = svg_items[[mode, plan]]
                old_items.each(&:dispose)
            end
            svg_io.rewind
            renderer, items = display_svg(svg_io)
            svg_items[[mode, plan]] = items

        ensure
            svg_io.close if svg_io
        end

        def clear
            renderers.clear
            stack.clear
            scene.clear
            svg_items.clear
            svg.clear
            task_from_id.clear
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

        def display_svg(io)
            # Build a two-way mapping from the SVG IDs and the task objects
            svgid_to_task = Hash.new
            svg_objects = Set.new

            if !io.respond_to?(:read)
                path = io
                svg_data = File.read(io)
            else
                path = io.path
                svg_data = io.read
            end
            puts "data: #{data}"

            svg[path.gsub(/\.svg$/, '')] = svg_data = svg_data.dup
            xml = Nokogiri::XML(svg_data)
            xml.children.children.children.each do |el|
                title = (el/"title")
                next if title.empty?

                id = title[0].content
                if id =~ /^(?:inputs|outputs|label)(\d+)$/ # this node is a part of a task / composition
                    id = $1
                    task = task_from_id[Integer(id)]
                    svgid_to_task[el['id']] = task
                end
                svg_objects << el['id']
            end

            renderer = (@renderers[path]  = Qt::SvgRenderer.new(Qt::ByteArray.new(svg_data)))

            all_items = []

            # Now, add separate graphics items for each of the tasks, so that we
            # are able to interact with them
            @graphicsitem_to_task = Hash.new
            svg_objects.each do |svgid|
                pos = renderer.matrixForElement(svgid).
                    map(renderer.bounds_on_element(svgid).top_left)

                item = Qt::GraphicsSvgItem.new
                all_items << item

                item.shared_renderer = renderer
                item.element_id = svgid
                item.pos = pos

                class << item
                    attr_accessor :svgid
                    attr_accessor :window
                end
                item.window = self
                item.svgid  = svgid

                if task = svgid_to_task[svgid]
                    graphicsitem_to_task[item] = task

                    class << item
                        attr_accessor :task
                    end
                    item.task   = task
                end
                scene.add_item(item)
            end

            view.update
            return renderer, all_items
        end

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
