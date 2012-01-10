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

            has_errors = false
            # Instanciate each specialization separately, to make sure that
            # everything's OK
            #
            # If there is a problem, mark the composition in red
            cmp.specializations.each_value do |spec|
                begin
                    cmp.instanciate_specialization(spec, [spec])
                rescue Exception => e
                    has_errors = true
                    break
                end
            end

            item = Qt::TreeWidgetItem.new(root_compositions)
            item.set_text(0, name)
            item.set_data(0, Qt::UserRole, Qt::Variant.new(1))
            if has_errors
                item.set_background(0, Qt::Brush.new(Qt::Color.new(255, 128, 128)))
            end
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
        @specializations = Hash.new
    end

    def clickedSpecialization(obj_as_variant)
        object = obj_as_variant.value
        if specializations.values.include?(object)
            clicked  = object.model.applied_specializations.dup.to_set
            selected = current_model.applied_specializations.dup.to_set

            if clicked.all? { |s| selected.include?(s) }
                # This specialization is already selected, remove it
                clicked.each { |s| selected.delete(s) }
                new_selection = selected

                new_merged_selection = new_selection.inject(Orocos::RobyPlugin::CompositionModel::Specialization.new) do |merged, s|
                    merged.merge(s)
                end
            else
                # This is not already selected, add it to the set. We have to
                # take care that some of the currently selected specializations
                # might not be compatible
                new_selection = clicked
                new_merged_selection = new_selection.inject(Orocos::RobyPlugin::CompositionModel::Specialization.new) do |merged, s|
                    merged.merge(s)
                end

                selected.each do |s|
                    if new_merged_selection.compatible_with?(s)
                        new_selection << s
                        new_merged_selection.merge(s)
                    end
                end
            end

            new_model = current_model.root_model.instanciate_specialization(new_merged_selection, new_selection)
            render_model(new_model)
        end
    end
    slots 'clickedSpecialization(QVariant&)'

    def clear
        super
        specializations.clear
    end

    def render_specialization_graph(root_model)
        specializations = Hash.new
        root_model.specializations.each_value.map do |spec|
            task_model = root_model.instanciate_specialization(spec, [spec])
            Roby.plan.add(task = task_model.new)
            specializations[spec] = task
        end

        specializations
    end

    def render_model(model, annotations = [])
        clear
        @current_model = model

        if model <= Orocos::RobyPlugin::Composition
            Roby.plan.clear
            @specializations = render_specialization_graph(model.root_model)

            current_specializations, incompatible_specializations = [], Hash.new
            if model.root_model != model
                current_specializations = model.applied_specializations.map { |s| specializations[s] }

                incompatible_specializations = specializations.dup
                incompatible_specializations.delete_if do |spec, task|
                    model.applied_specializations.all? { |applied_spec| applied_spec.compatible_with?(spec) }
                end
            end

            Qt::Object.connect(self, SIGNAL('selectedObject(QVariant&,QPoint&)'),
                               self, SLOT('clickedSpecialization(QVariant&)'))
            display_options = {
                :accessor => :each_compatible_specialization,
                :dot_edge_mark => '--',
                :dot_graph_type => 'graph',
                :graphviz_tool => 'fdp',
                :highlights => current_specializations,
                :toned_down => incompatible_specializations.values
            }
            push_plan('Specializations', 'relation_to_dot',
                      Roby.plan, Roby.orocos_engine,
                      display_options)
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
            push_plan('Dataflow', 'dataflow', Roby.plan, Roby.orocos_engine, :annotations => annotations)
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

class SystemModelBrowser < Qt::Widget
    attr_reader :current_model
    attr_reader :annotation_actions
    attr_reader :model_display

    def initialize(main = nil)
        super

        main_layout = Qt::VBoxLayout.new(self)

        menu_layout = Qt::HBoxLayout.new
        main_layout.add_layout(menu_layout)
        annotation_button = Qt::PushButton.new("Annotations", self)
        annotation_menu = Qt::Menu.new
        @annotation_actions = []
        Orocos::RobyPlugin::Graphviz.available_annotations.each do |ann_name|
            act = Qt::Action.new(ann_name, annotation_menu)
            act.checkable = true
            annotation_menu.add_action(act)
            annotation_actions << act
            act.connect(SIGNAL('triggered()')) do
                render_current_model
            end
        end
        annotation_button.menu = annotation_menu
        menu_layout.add_widget(annotation_button)
        menu_layout.add_stretch(1)

        layout = Qt::HBoxLayout.new
        main_layout.add_layout(layout)
        splitter = Qt::Splitter.new(self)
        layout.add_widget(splitter)
        model_list = ModelListWidget.new(splitter)
        splitter.add_widget(model_list)
        @model_display = ModelDisplayView.new(splitter)
        splitter.add_widget(model_display.view)
        splitter.set_stretch_factor(1, 2)

        model_list.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, col|
            if model = model_list.model_name_to_object[item.text(0)]
                @current_model = model
                render_current_model
            end
        end
        model_list.populate
    end

    def render_current_model
        annotations = annotation_actions.
            find_all { |act| act.checked? }.
            map(&:text)
        model_display.render_model(current_model, annotations)
    end
end

Roby::TaskStructure.relation 'SpecializationCompatibilityGraph', :child_name => :compatible_specialization, :dag => false

Scripts.run do
    if remaining.empty?
        # Load all task libraries
        Orocos.available_task_libraries.each_key do |name|
            Roby.app.using_task_library(name)
        end
    else
        files, projects = remaining.partition { |path| File.file?(path) }
        projects.each do |project_name|
            Roby.app.use_deployments_from(project_name)
        end
        files.each do |file|
            Roby.app.orocos_engine.load_composite_file file
        end
    end

    Roby.app.orocos_engine.prepare

    main = SystemModelBrowser.new
    main.resize(800, 500)
    main.show

    $qApp.exec

    # # Do compute the automatic connections
    # Roby.app.orocos_system_model.each_composition do |c|
    #     c.compute_autoconnection
    # end
end
