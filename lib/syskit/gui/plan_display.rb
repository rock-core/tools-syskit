require 'utilrb/qt/variant/from_ruby'
module Syskit
module GUI
    # Widget used to display a network of Orocos tasks represented in a Roby
    # plan
    #
    # The technique used here is to convert the network to dot and then svg
    # using Syskit::Graphviz. The SVG is then postprocessed to allow
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
                        selectedObject(Qt::Variant.from_ruby(sel.real_object), event.globalPos)
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
                num_steps = degrees / 60.0

                old = self.current_scaling
                new = old + num_steps
                if new.abs < 1
                    if old > 0
                        @current_scaling = -1
                    else
                        @current_scaling = 1
                    end
                else
                    @current_scaling = new
                end

                current_scaling = (self.current_scaling * 10).round / 10.0
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
        # A mapping from objects to their QSvgItem
        attr_reader :object_to_svgitem
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
        # The menu that displays all the excluded models actions
        attr_reader :excluded_models_menu
        # The push button that controls which annotations are displayed (only
        # enabled if mode == 'dataflow')
        attr_reader :annotation_btn
        # The set of Qt::Action objects that represent the user selection w.r.t.
        # the annotations
        attr_reader :annotation_act
        # The button that allows to save the graph as an SVG
        attr_reader :svg_export_btn

        DEFAULT_ANNOTATIONS = []
        DEFAULT_REMOVE_COMPOSITIONS = true
        DEFAULT_EXCLUDED_MODELS = %w{Syskit::Logger::Logger}

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
            @object_to_svgitem = Hash.new

            # Add a button bar
            @remove_compositions_btn = Qt::PushButton.new("Hide Compositions", self)
            remove_compositions_btn.checkable = true
            remove_compositions_btn.checked = DEFAULT_REMOVE_COMPOSITIONS
            @excluded_models_btn     = Qt::PushButton.new("Hidden Models", self)
            @annotation_btn = Qt::PushButton.new("Annotations", self)

            # Generate the menu for annotations
            annotation_menu = Qt::Menu.new(annotation_btn)
            @annotation_act = Hash.new
            Syskit::Graphviz.available_annotations.sort.each do |ann_name|
                act = Qt::Action.new(ann_name, annotation_menu)
                act.checkable = true
                act.checked = DEFAULT_ANNOTATIONS.include?(ann_name)
                annotation_menu.add_action(act)
                annotation_act[ann_name] = act
            end
            annotation_btn.menu = annotation_menu

            # Generate the menu for hidden models
            @excluded_models_menu = Qt::Menu.new(excluded_models_btn)
            @excluded_models_act = Hash.new
            Syskit::Component.each_submodel.sort_by(&:name).each do |model|
                next if model <= Syskit::Deployment

                act = Qt::Action.new(model.short_name, excluded_models_menu)
                act.checkable = true
                act.checked = DEFAULT_EXCLUDED_MODELS.include?(model.name)
                excluded_models_act[model] = act
                excluded_models_menu.add_action(act)
            end
            excluded_models_btn.menu = excluded_models_menu

            # Add a button to export the SVG to a file
            @svg_export_btn = Qt::PushButton.new('SVG Export')

            # Lay the UI out
            root_layout = Qt::VBoxLayout.new(self)
            button_bar_layout = Qt::HBoxLayout.new
            root_layout.add_layout(button_bar_layout)
            button_bar_layout.add_widget(remove_compositions_btn)
            button_bar_layout.add_widget(excluded_models_btn)
            button_bar_layout.add_widget(annotation_btn)
            button_bar_layout.add_widget(svg_export_btn)
            button_bar_layout.add_stretch(0)
            root_layout.add_widget(view)

            self.options = Hash.new

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
            svg_export_btn.connect(SIGNAL('clicked()')) do
                if @svg_data && (path = Qt::FileDialog.get_save_file_name(nil, "SVG Export"))
                    File.open(path, 'w') do |io|
                        io.write @svg_data
                    end
                end
            end

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        # The plan this display acts on
        attr_accessor :plan
        # The display mode ('hierarchy' or 'dataflow')
        attr_reader :mode
        # Sets the display mode ('hierarchy' or 'dataflow'). Enables or disables
        # the annotation_btn if mode is dataflow or not
        def mode=(mode)
            annotation_btn.enabled = (mode == 'dataflow') || (mode == 'hierarchy')
            remove_compositions_btn.visible = (mode != 'relation_to_dot')
            excluded_models_btn.visible = (mode != 'relation_to_dot')
            @mode = mode
        end
        # The display options, as a hash
        attr_reader :options
        # Sets some display options, updating the GUI in the process
        def options=(options)
            if excluded_models_menu.visible?
                default_excluded_models = Array.new
                excluded_models_act.each do |model, action|
                    default_excluded_models << model if action.checked?
                end
            end
            default_remove_compositions =
                if remove_compositions_btn.visible?
                    remove_compositions_btn.checked?
                end

            default_annotations = Array.new
            annotation_act.each do |act_name, act|
                default_annotations << act_name if act.checked?
            end

            gui_options, other_options = Kernel.filter_options options,
                :excluded_models => default_excluded_models,
                :remove_compositions => default_remove_compositions,
                :annotations => default_annotations
            @options = other_options.merge(gui_options)

            if gui_options[:excluded_models]
                excluded_models_btn.show
                excluded_models_act.each do |model, action|
                    action.checked = gui_options[:excluded_models].include?(model)
                end
            else
                excluded_models_btn.hide
                excluded_models_act.each do |model, action|
                    action.checked = true
                end
            end
            if gui_options[:remove_compositions].nil?
                remove_compositions_btn.hide
                remove_compositions_btn.checked = false
            else
                remove_compositions_btn.show
                remove_compositions_btn.checked = gui_options[:remove_compositions]
            end
            annotation_act.each do |act_name, act|
                act.checked = gui_options[:annotations].include?(act_name)
            end
        end

        def display
            clear

            # Filter the option hash based on the current mode
            options = self.options.dup
            if mode != 'dataflow'
                options.delete(:annotations)
            end
            if mode == 'relation_to_dot'
                options.delete(:remove_compositions)
                options.delete(:excluded_models)
            end

            # Update the composition display option based on the information in
            # +options+
            begin
                render_plan(mode, plan, options)
                emit updated(Qt::Variant.new)
            rescue Exception => e
                emit updated(Qt::Variant.from_ruby(e))
            end
        end

        signals 'updated(QVariant&)'

        def render_plan(mode, plan, options)
            svg_io = Tempfile.open(mode)
            Syskit::Graphviz.new(plan).
                to_file(mode, 'svg', svg_io, options)

            plan.each_task do |task|
                index = index_to_object.size
                index_to_object.push(task)
                ruby_id_to_index[task.object_id] = index
            end
            svg_io.rewind
            renderer, items = display_svg(svg_io)

            item = items.map do |w|
                if w.kind_of?(Qt::Widget)
                    scene.add_widget(w)
                else
                    w
                end
            end
            item = scene.create_item_group(item)

        ensure
            svg_io.close if svg_io
        end

        def clear
            renderers.clear
            scene.clear
            svg.clear
            index_to_object.clear
            ruby_id_to_index.clear
            svg_id_to_index.clear
            object_to_svgitem.clear
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

            @svg_data = svg_data.dup
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
                    object_to_svgitem[index_to_object[index]] = item
                end
            
                item.extend SvgObjectMapper
                item.plan_display = self
                scene.add_item(item)
            end

            view.update
            return renderer, all_items
        end

        def ensure_visible(object)
            # We might not have an item to display that object:
            #
            # * dot crashed
            # * the class of the object are currently hidden
            if item = object_to_svgitem[object]
                view.ensureVisible(item)
            end
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
end
