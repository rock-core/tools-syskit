module Ui
    # Widget that allows to instanciate a composition step by step
    class InstanciateComposition
        attr_reader :scene
        attr_reader :view
        attr_reader :model
        attr_reader :selection

        def initialize(main = nil)
            @selection = Hash.new

            @scene = Qt::GraphicsScene.new
            @view  = Qt::GraphicsView.new(scene, main)
            @renderers = Hash.new

            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
        end

        def engine
            Roby.app.orocos_engine
        end
        def plan
            Roby.plan
        end

        attr_reader :task_from_id
        attr_reader :model

        def model=(model)
            @model = model
            selection.clear
            update
        end

        HIERARCHY_DATAFLOW_MARGIN = 50
        attr_reader :main
        def update
            engine.clear
            plan.clear

            @main = engine.add_mission(model).use(selection)
            engine.prepare
            engine.instanciate
            engine.merge_identical_tasks
            plan.engine.garbage_collect
            engine.to_svg('hierarchy', 'hierarchy.svg')
            engine.to_svg('dataflow', 'dataflow.svg', false)

            @task_from_id = Hash.new
            plan.each_task do |task|
                task_from_id[task.object_id] = task
            end
            scene.clear
            hierarchy_items = display_svg('hierarchy.svg')
            dataflow_items  = display_svg('dataflow.svg')

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

        attr_reader :graphicsitem_to_task
        attr_reader :renderers
        attr_reader :task_items

        def role_path(task)
            if task == main.task
                return []
            end

            task_roles = task.each_role.to_a.first.last
            if task.parent_object?(main.task, Roby::TaskStructure::Dependency)
                task_roles.to_a
            else
                task.enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                    map { |parent_task| role_path(parent_task) }.
                    flatten.
                    map do |parent_role|
                        task_roles.map do |role|
                            "#{parent_role}.#{role}"
                        end
                    end.flatten
            end
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
                pos = renderer.matrixForElement(svgid).map(renderer.bounds_on_element(svgid).top_left)

                item = Qt::GraphicsSvgItem.new
                all_items << item

                item.shared_renderer = renderer
                item.element_id = svgid
                item.pos = pos

                class << item
                    attr_accessor :svgid
                end
                item.svgid  = svgid

                if task = svgid_to_task[svgid]
                    graphicsitem_to_task[item] = task

                    class << item
                        attr_accessor :task
                        attr_accessor :window
                    end
                    item.window = self
                    item.task   = task
                    def item.mousePressEvent(event)
                        super

                        models =
                            if task.respond_to?(:proxied_data_services)
                                task.proxied_data_services.map(&:model)
                            else [task.model]
                            end

                        # Get the task's role. We can safely assume the task
                        # has only one parent and is used for only one role
                        # in this parent
                        roles = window.role_path(task)

                        #Roby.app.orocos_engine.service_allocation_candidates.each do |service_model, candidates|
                        #    puts "#{service_model.name} =>\n    #{candidates.map(&:name).join("\n    ")}"
                        #end
                        candidates = models.map do |m|
                            Roby.app.orocos_engine.service_allocation_candidates[m]
                        end.compact.map(&:to_value_set).inject(:&)
                        candidates ||= ValueSet.new

                        current_selection = roles.find_all do |role_name|
                            window.selection[role_name]
                        end

                        puts "mouse pressed for #{self} (#{models.map(&:name).join(", ")}) [#{task}, #{roles.to_a.join(", ")}]"
                        menu = Qt::Menu.new
                        candidates = candidates.to_a.sort_by(&:name)
                        if candidates.empty? && current_selection.empty?
                            action = menu.add_action('No available selection')
                            action.enabled = false
                        end

                        deselection = Hash.new
                        current_selection.each do |role_name|
                            text = "Don't use for #{role_name}"
                            deselection[text] = role_name
                            menu.add_action(text)
                        end

                        selection = Hash.new
                        candidates.each do |m|
                            selection[m.name] = m
                            menu.add_action(m.name)
                        end
                        return unless action = menu.exec(event.screenPos)

                        if selected_model = selection[action.text]
                            roles.each do |child_name|
                                window.selection[child_name] = selected_model
                            end
                            puts "selected #{selected_model.short_name} for #{roles.to_a.join(", ")}"
                        elsif deselected_role = deselection[action.text]
                            window.selection.delete(deselected_role)
                        end

                        window.update
                    end
                end
                scene.add_item(item)
            end

            view.update
            all_items
        end
    end
end

