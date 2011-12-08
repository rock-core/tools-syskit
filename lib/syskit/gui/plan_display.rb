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
            @hierarchy_items = Array.new
            @dataflow_items  = Array.new
            @svg             = Hash.new
            @task_from_id = Hash.new

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        attr_reader :hierarchy_items
        attr_reader :dataflow_items
        attr_reader :error_text

        HIERARCHY_DATAFLOW_MARGIN = 50
        def update_view(plan, engine, display_options = Hash.new)
            default_exclude = []
            if defined? Orocos::RobyPlugin::Logger::Logger
                default_exclude << Orocos::RobyPlugin::Logger::Logger
            end

            display_options = Kernel.validate_options display_options,
                :remove_compositions => false,
                :excluded_tasks => default_exclude.to_value_set,
                :annotations => Set.new

            if error_text
                scene.remove_item(error_text)
                @error_text = nil
            end

            renderers.clear
            hierarchy_io = Tempfile.open('hierarchy')
            engine.to_svg('hierarchy', hierarchy_io)
            dataflow_io = Tempfile.open('dataflow')
            engine.to_svg('dataflow', dataflow_io, display_options[:remove_compositions],
                         display_options[:excluded_tasks],
                         display_options[:annotations])

            task_from_id.clear
            plan.each_task do |task|
                task_from_id[task.object_id] = task
            end
            hierarchy_items.each(&:dispose)
            dataflow_items.each(&:dispose)
            scene.clear
            @hierarchy_items = display_svg(hierarchy_io.path)
            @dataflow_items  = display_svg(dataflow_io.path)

            r = renderers[hierarchy_io.path]
            bottom = hierarchy_items.map do |i|
                r.matrixForElement(i.svgid).
                    map(r.bounds_on_element(i.svgid).bottom_left).
                    y
            end.max
            dataflow_items.each do |item|
                item.move_by(0, bottom + HIERARCHY_DATAFLOW_MARGIN)
            end
        ensure
            hierarchy_io.close if hierarchy_io
            dataflow_io.close if dataflow_io
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

        def display_svg(filename)
            # Build a two-way mapping from the SVG IDs and the task objects
            svgid_to_task = Hash.new
            svg_objects = Set.new

            svg[filename.gsub(/\.svg$/, '')] = svg_data = File.read(filename).dup
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

            renderer = (@renderers[filename]  = Qt::SvgRenderer.new(filename))

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
            all_items
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
