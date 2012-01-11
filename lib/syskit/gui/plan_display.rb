module Ui
    # Widget used to display a network of Orocos tasks represented in a Roby
    # plan
    #
    # The technique used here is to convert the network to dot and then svg
    # using Orocos::RobyPlugin::Graphviz. The SVG is then postprocessed to allow
    # the creation of an association between graphical elements (identified
    # through their SVG object ID) and the graphical representation.
    class PlanDisplay < Qt::Widget
        # Module used to extend the Qt::GraphicsView widget to provide events on
        # click, and zoom with Ctrl + Wheel
        module GraphicsViewExtension
            # The underlying PlanDisplay object
            attr_accessor :plan_display

            # The current scaling factor
            attribute(:current_scaling) { 1 }

            # Handler that emits the selectedObject signal on the underlying
            # PlanDisplay instance if the user clicks on a SVG item that
            # represents a registered plan object
            def mousePressEvent(event)
                items = self.items(event.pos)
                items = items.find_all do |i|
                    i.respond_to?(:real_object) &&
                        i.real_object
                end
                if (sel = items.first) && sel.real_object
                    emit plan_display.
                        selectedObject(Qt::Variant.fromValue(sel.real_object), event.globalPos)
                end
                event.accept
            end

            # Handler that changes the current_scaling factor (and updates the
            # view) on Ctrl + Wheel events
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

        # The push button that controls whether compositions are displayed or
        # not
        attr_reader :remove_compositions_btn
        # The push button that controls which models should be displayed or
        # hidden
        attr_reader :excluded_models_btn
        # The set of Qt::Action objects that represent the user selection w.r.t.
        # hidden models, as a map from a model object to the corresponding
        # Qt::Action object
        attr_reader :excluded_models_act
        # The push button that controls which annotations are displayed (only
        # enabled if mode == 'dataflow')
        attr_reader :annotation_btn
        # The set of Qt::Action objects that represent the user selection w.r.t.
        # the annotations
        attr_reader :annotation_act

        DEFAULT_ANNOTATIONS = %w{task_info port_details}
        DEFAULT_REMOVE_COMPOSITIONS = false
        DEFAULT_excluded_models = %w{Orocos::RobyPlugin::Logger::Logger}

        def initialize(main = nil)
            super(main)
            @scene           = Qt::GraphicsScene.new(main)
            @view            = Qt::GraphicsView.new(scene, self)
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

            # Add a button bar
            @remove_compositions_btn = Qt::PushButton.new("Hide Compositions", self)
            remove_compositions_btn.checkable = true
            remove_compositions_btn.checked = DEFAULT_REMOVE_COMPOSITIONS
            @excluded_models_btn     = Qt::PushButton.new("Hidden Models", self)
            @annotation_btn = Qt::PushButton.new("Annotations", self)

            # Generate the menu for annotations
            annotation_menu = Qt::Menu.new(annotation_btn)
            @annotation_act = Hash.new
            Orocos::RobyPlugin::Graphviz.available_annotations.each do |ann_name|
                act = Qt::Action.new(ann_name, annotation_menu)
                act.checkable = true
                act.checked = DEFAULT_ANNOTATIONS.include?(ann_name)
                annotation_menu.add_action(act)
                annotation_act[ann_name] = act
            end
            annotation_btn.menu = annotation_menu

            # Generate the menu for hidden models
            excluded_models_menu = Qt::Menu.new(excluded_models_btn)
            @excluded_models_act = Hash.new
            Roby.app.orocos_system_model.each_model.sort_by(&:name).each do |model|
                next if model <= Orocos::RobyPlugin::Deployment

                act = Qt::Action.new(model.short_name, excluded_models_menu)
                act.checkable = true
                act.checked = DEFAULT_excluded_models.include?(model.name)
                excluded_models_act[model] = act
                excluded_models_menu.add_action(act)
            end
            excluded_models_btn.menu = excluded_models_menu

            # Lay the UI out
            root_layout = Qt::VBoxLayout.new(self)
            button_bar_layout = Qt::HBoxLayout.new
            root_layout.add_layout(button_bar_layout)
            button_bar_layout.add_widget(remove_compositions_btn)
            button_bar_layout.add_widget(excluded_models_btn)
            button_bar_layout.add_widget(annotation_btn)
            root_layout.add_widget(view)

            # Add action handlers
            annotation_act.each do |ann_name, act|
                act.connect(SIGNAL('toggled(bool)')) do |checked|
                    if checked then options[:annotations] << ann_name
                    else options[:annotations].delete(ann_name)
                    end
                    display
                end
            end
            remove_compositions_btn.connect(SIGNAL('toggled(bool)')) do |checked|
                options[:remove_compositions] = checked
                display
            end
            excluded_models_act.each do |model, act|
                act.connect(SIGNAL('toggled(bool)')) do |checked|
                    if checked then options[:excluded_models] << model
                    else options[:excluded_models].delete(model)
                    end
                    display
                end
            end

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        # The plan this display acts on
        attr_accessor :plan
        # The engine this display uses to generate the display
        attr_accessor :engine
        # The display mode ('hierarchy' or 'dataflow')
        attr_reader :mode
        # Sets the display mode ('hierarchy' or 'dataflow'). Enables or disables
        # the annotation_btn if mode is dataflow or not
        def mode=(mode)
            annotation_btn.enabled = (mode == 'dataflow')
            remove_compositions_btn.enabled = (mode != 'relation_to_dot')
            excluded_models_btn.enabled = (mode != 'relation_to_dot')
            @mode = mode
        end
        # The display options, as a hash
        attr_reader :options
        # Sets some display options, updating the GUI in the process
        def options=(options)
            default_excluded_models = Array.new
            excluded_models_act.each do |model, action|
                default_excluded_models << model if action.checked?
            end
            default_remove_compositions = remove_compositions_btn.checked?
            default_annotations = Array.new
            annotation_act.each do |act_name, act|
                default_annotations << act_name if act.checked?
            end

            gui_options, other_options = Kernel.filter_options options,
                :excluded_models => default_excluded_models,
                :remove_compositions => default_remove_compositions,
                :annotations => default_annotations
            excluded_models_act.each do |model, action|
                action.checked = gui_options[:excluded_models].include?(model)
            end
            remove_compositions_btn.checked = gui_options[:remove_compositions]
            annotation_act.each do |act_name, act|
                act.checked = gui_options[:annotations].include?(act_name)
            end

            @options = other_options.merge(gui_options)
        end

        def display
            clear

            # Filter the option hash based on the current mode
            options = self.options
            if mode != 'dataflow'
                options.delete(:annotations)
            end
            if mode == 'relation_to_dot'
                options.delete(:remove_compositions)
                options.delete(:excluded_models)
            end

            # Update the composition display option based on the information in
            # +options+
            push_plan('', mode, plan, engine, options)
            render
        end

        attr_reader :error_text
        attr_reader :stack
        attr_accessor :title_font

        def render_plan(mode, plan, engine, options)
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

        # Module used to extend the SVG items that represent a task in the plan
        #
        # The #real_object method can then be used to get the actual plan object
        # out of the SVG item
        module SvgObjectMapper
            # The PlanDisplay object to which we are attached
            attr_accessor :plan_display

            # The task object that is represented by this SVG item
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

        signals 'selectedObject(QVariant&, QPoint&)'

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
