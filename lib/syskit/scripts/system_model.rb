require 'roby/standalone'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: scripts/orocos/system_model [options]
Loads the models listed by robot_name, and outputs their model structure
    EOD
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'orocos'
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true

Scripts.setup_output("system_model", Roby.app.orocos_system_model) do
    Roby.app.orocos_system_model.to_dot
end

app = Qt::Application.new(ARGV)

require 'orocos/roby/gui/plan_display'

class ModelListWidget < Qt::TreeWidget
    attr_reader :root_services
    attr_reader :root_compositions
    attr_reader :model_name_to_object

    def initialize(parent = nil)
        super

        @model_name_to_object = Hash.new
        @root_services = Qt::TreeWidgetItem.new(self)
        root_services.set_text(0, "Data Services")
        @root_compositions = Qt::TreeWidgetItem.new(self)
        root_compositions.set_text(0, "Compositions")
        set_header_label("")
    end

    def populate
        services = Roby.app.orocos_system_model.each_data_service.to_a
        services.sort_by { |srv| srv.name }.each do |srv|
            services << srv
            name = srv.name.gsub(/.*DataServices::/, '')
            model_name_to_object[name] = srv

            item = Qt::TreeWidgetItem.new(root_services)
            item.set_text(0, name)
            item.set_data(0, Qt::UserRole, Qt::Variant.new(0))
        end

        compositions = Roby.app.orocos_system_model.each_composition.to_a
        compositions.sort_by { |srv| srv.name }.each do |cmp|
            name = cmp.name.gsub(/.*Compositions::/, '')
            model_name_to_object[name] = cmp

            item = Qt::TreeWidgetItem.new(root_compositions)
            item.set_text(0, name)
            item.set_data(0, Qt::UserRole, Qt::Variant.new(1))
        end
    end

    def clear
        @model_name_to_object.clear
        @root_services.clear
        @root_compositions.clear
    end
end

# Qt::Internal::setDebug(Qt::QtDebugChannel::QTDB_VIRTUAL)
# Qt::Internal::setDebug(Qt::QtDebugChannel::QTDB_GC)

class ModelDisplayView < Ui::PlanDisplay
    attr_reader :specializations
    attr_reader :current_model

    def initialize(parent = nil)
        super
        @specializations = ValueSet.new
    end

    def clickedSpecialization(obj_as_variant)
        object = obj_as_variant.value
        if specializations.include?(object)
            if object.model != current_model
                render_model(object.model)
            end
        end
    end
    slots 'clickedSpecialization(QVariant&)'

    def clear
        super
        specializations.clear
    end

    def render_specialization_graph(root_model)
        models = root_model.instanciate_all_possible_specializations
        models << root_model

        puts "#{models.size} models"
        models.each do |m|
            pp m
        end

        model_to_task = Hash.new
        parents = Hash.new
        models.each do |composition_model|
            Roby.plan.add(task = composition_model.new)
            model_to_task[composition_model] = task
            specializations << task
            parents[task] = Set.new
        end

        # Now generate the dependency links
        models.each do |composition_model|
            models.each do |other_model|
                next if other_model == composition_model
                if (other_model.applied_specializations & composition_model.applied_specializations) == composition_model.applied_specializations
                    parents[model_to_task[other_model]] << model_to_task[composition_model]
                end
            end
        end
        parents.each do |task, task_parents|
            task_parents.each do |parent_task|
                if task_parents.none? { |p| p != parent_task && parents[p].include?(parent_task) }
                    parent_task.depends_on(task)
                end
            end
        end
    end

    def render_model(model)
        clear

        if model <= Orocos::RobyPlugin::Composition
            Roby.plan.clear
            render_specialization_graph(model.root_model)

            Qt::Object.connect(self, SIGNAL('selectedObject(QVariant&)'),
                               self, SLOT('clickedSpecialization(QVariant&)'))
            display_options = { :annotations => [] }
            push_plan('Specializations', 'hierarchy', Roby.plan, Roby.orocos_engine, display_options)
        end

        Roby.plan.clear
        requirements = Orocos::RobyPlugin::Engine.
            create_instanciated_component(Roby.app.orocos_engine, "", model)
        task = requirements.instanciate(
            Roby.app.orocos_engine,
            Orocos::RobyPlugin::DependencyInjectionContext.new)
        Roby.plan.add(task)

        if model <= Orocos::RobyPlugin::Composition
            push_plan('Task Dependency Hierarchy', 'hierarchy', Roby.plan, Roby.orocos_engine, Hash.new)
            push_plan('Dataflow', 'dataflow', Roby.plan, Roby.orocos_engine, :annotations => ['port_details', 'task_info', 'connection_policy'])
        else
            push_plan('Interface', 'dataflow', Roby.plan, Roby.orocos_engine, :annotations => ['port_details'])
        end

        services = []
        task.model.each_data_service do |service_name, service|
            model_hierarchy = service.model.ancestors.
                find_all do |m|
                m.kind_of?(Orocos::RobyPlugin::DataServiceModel) &&
                    m != Orocos::RobyPlugin::DataService &&
                    m != task.model
                end

            model_hierarchy.each do |m|
                port_mappings = service.port_mappings_for(m).dup
                port_mappings.delete_if do |from, to|
                    from == to
                end
                model_name = m.short_name.gsub("DataServices::", "")
                if !port_mappings.empty?
                    services << "#{model_name} #{port_mappings}"
                else
                    services << model_name
                end
            end
        end
        label = Qt::Label.new(services.join("\n"))
        label.background_role = Qt::Palette::NoRole
        push("Provided Services", label)
        render
    end
end

Scripts.run do
    files, projects = remaining.partition { |path| File.file?(path) }
    projects.each do |project_name|
        Roby.app.use_deployments_from(project_name)
    end
    files.each do |file|
        Roby.app.orocos_engine.load_composite_file file
    end
    Roby.app.orocos_engine.prepare

    main = Qt::Widget.new
    layout = Qt::HBoxLayout.new(main)
    splitter = Qt::Splitter.new(main)
    layout.add_widget(splitter)
    model_list = ModelListWidget.new(splitter)
    splitter.add_widget(model_list)
    display = ModelDisplayView.new(splitter)
    splitter.add_widget(display.view)
    splitter.set_stretch_factor(1, 2)

    model_list.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, col|
        if model = model_list.model_name_to_object[item.text(0)]
            display.render_model(model)
        end
    end
    model_list.populate
    main.resize(800, 500)
    main.show

    $qApp.exec

    # # Do compute the automatic connections
    # Roby.app.orocos_system_model.each_composition do |c|
    #     c.compute_autoconnection
    # end
end
