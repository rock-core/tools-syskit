require 'roby'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

require 'nokogiri'
require 'Qt4'

module Ui
    class InstanciateComposition
        attr_reader :scene
        attr_reader :view
        attr_reader :model
        attr_reader :selection

        def initialize(model)
            @model = model
            @selection = Hash.new

            @scene = Qt::GraphicsScene.new
            @view  = Qt::GraphicsView.new(scene)
            view.viewport_update_mode = Qt::GraphicsView::FullViewportUpdate
            view.scale(0.8, 0.8)
            view.resize 640, 480
            view.show
        end

        def engine
            Roby.app.orocos_engine
        end
        def plan
            Roby.plan
        end

        attr_reader :task_from_id

        attr_reader :main
        def update
            engine.clear
            plan.clear

            @main = engine.add_mission(model).use(selection)
            engine.prepare
            engine.instanciate
            engine.merge_identical_tasks
            plan.engine.garbage_collect
            engine.to_svg('bla.svg')

            @task_from_id = Hash.new
            plan.each_task do |task|
                task_from_id[task.object_id] = task
            end
            scene.clear
            display_svg('bla.svg')
        end

        attr_reader :graphicsitem_to_task
        attr_reader :renderer
        attr_reader :main_item
        attr_reader :task_items

        def role_path(task)
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

            @renderer  = Qt::SvgRenderer.new(filename)

            # Add the main SVG graphics item
            # @main_item = Qt::GraphicsSvgItem.new
            # main_item.shared_renderer = renderer
            # scene.add_item(main_item)

            # Now, add separate graphics items for each of the tasks, so that we
            # are able to interact with them
            @graphicsitem_to_task = Hash.new
            svg_objects.each do |svgid|
                pos = renderer.matrixForElement(svgid).map(renderer.bounds_on_element(svgid).top_left)

                item = Qt::GraphicsSvgItem.new
                item.shared_renderer = renderer
                item.element_id = svgid
                scene.add_item(item)
                item.pos = pos
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

                        model =
                            if task.respond_to?(:proxied_data_service)
                                task.proxied_data_service.model
                            else task
                            end

                        # Get the task's role. We can safely assume the task
                        # has only one parent and is used for only one role
                        # in this parent
                        roles = window.role_path(task)

                        #Roby.app.orocos_engine.service_allocation_candidates.each do |service_model, candidates|
                        #    puts "#{service_model.name} =>\n    #{candidates.map(&:name).join("\n    ")}"
                        #end
                        candidates = Roby.app.orocos_engine.
                            service_allocation_candidates[model] || Array.new

                        current_selection = roles.find_all do |role_name|
                            window.selection[role_name]
                        end

                        puts "mouse pressed for #{self} (#{model.name}) [#{task}, #{roles.to_a.join(", ")}]"
                        return if candidates.empty? && current_selection.empty?

                        menu = Qt::Menu.new
                        candidates = candidates.to_a.sort_by(&:name)

                        deselection = Hash.new
                        current_selection.each do |role_name|
                            text = "Don't use for #{role_name}"
                            deselection[text] = role_name
                            menu.add_action(text)
                        end

                        selection = Hash.new
                        candidates.each do |model|
                            selection[model.name] = model
                            menu.add_action(model.name)
                        end
                        return unless action = menu.exec(event.screenPos)

                        if selected_model = selection[action.text]
                            roles.each do |child_name|
                                window.selection[child_name] = selected_model
                            end
                            puts "selected #{selected_model} for #{roles.to_a.join(", ")}"
                        elsif deselected_role = deselection[action.text]
                            window.selection.delete(deselected_role)
                        end

                        window.update
                    end
                end
            end

            view.update

        end
    end
end

debug = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate_gui [options]"
    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name used as context to the deployment') do |name|
        robot_name, robot_type = name.split(',')
        Roby.app.robot(name, robot_type||robot_name)
    end
    opt.on('--debug', "turn debugging output on") do
        debug = true
    end
    opt.on_tail('-h', '--help', 'this help message') do
	STDERR.puts opt
	exit
    end
end
remaining = parser.parse(ARGV)

error = Roby.display_exception do
    begin
        tic = Time.now
        Roby.app.using_plugins 'orocos'
        Roby.app.setup
        Roby.app.filter_backtraces = !debug
        toc = Time.now
        STDERR.puts "loaded Roby application in %.3f seconds" % [toc - tic]
        if debug
            Orocos::RobyPlugin::Engine.logger = Logger.new(STDOUT)
            Orocos::RobyPlugin::Engine.logger.formatter = Roby.logger.formatter
            Orocos::RobyPlugin::Engine.logger.level = Logger::DEBUG
        end

        Dir.chdir(APP_DIR)
        Roby.app.setup_global_singletons
        Roby.app.setup_drb_server

        app  = Qt::Application.new(ARGV)
        ui = Ui::InstanciateComposition.new(Orocos::RobyPlugin::Compositions::PoseEstimation)
        ui.update
        app.exec

    ensure Roby.app.stop_process_servers
    end
end

