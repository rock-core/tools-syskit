module Ui
    class PlanDisplay < Qt::Object
        attr_reader :scene
        attr_reader :view
        attr_reader :task_from_id
        attr_reader :graphicsitem_to_task
        attr_reader :renderers

        def initialize(main = nil)
            super()
            @scene = Qt::GraphicsScene.new
            @view  = Qt::GraphicsView.new(scene, main)
            @renderers = Hash.new
            @hierarchy_items = Array.new
            @dataflow_items = Array.new

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        attr_reader :hierarchy_items
        attr_reader :dataflow_items
        attr_reader :error_text

        HIERARCHY_DATAFLOW_MARGIN = 50
        def update_view(plan, engine)
            if error_text
                scene.remove_item(error_text)
                @error_text = nil
            end

            engine.to_svg('hierarchy', 'hierarchy.svg')
            engine.to_svg('dataflow', 'dataflow.svg', true)

            @task_from_id = Hash.new
            plan.each_task do |task|
                task_from_id[task.object_id] = task
            end
            hierarchy_items.each(&:dispose)
            dataflow_items.each(&:dispose)
            scene.clear
            @hierarchy_items = display_svg('hierarchy.svg')
            @dataflow_items  = display_svg('dataflow.svg')

            r = renderers['hierarchy.svg']
            bottom = hierarchy_items.map do |i|
                r.matrixForElement(i.svgid).
                    map(r.bounds_on_element(i.svgid).bottom_left).
                    y
            end.max
            dataflow_items.each do |item|
                item.move_by(0, bottom + HIERARCHY_DATAFLOW_MARGIN)
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
            error_text.plain_text = message + "\n\n" + Roby.format_exception(error).join("\n")
            error_text.default_text_color = Qt::Color.new('red')
        end

        def display_svg(filename)
            # Build a two-way mapping from the SVG IDs and the task objects
            svgid_to_task = Hash.new
            svg_objects = Set.new

            xml = Nokogiri::XML(File.read(filename))
            xml.children.children.children.each do |el|
                title = (el/"title")
                next if title.empty?

                id = title[0].content
                if id =~ /^\d+$/ # this node represents a task/composition
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
    end
end
