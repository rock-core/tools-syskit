require 'roby/standalone'
require 'syskit/scripts/common'
require 'Qt'
require 'syskit/gui/stacked_display'

Scripts = Syskit::Scripts

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: system_model [options]
Loads the models listed by robot_name, and outputs their model structure
    EOD
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'syskit'
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Syskit.conf.ignore_load_errors = true

app = Qt::Application.new(ARGV)

require 'syskit/gui/plan_display'

class ModelListWidget < Qt::TreeWidget
    # The TreeWidgetItem that is root of all the data service items
    attr_reader :root_services
    # The TreeWidgetItem that is root of all the composition items
    attr_reader :root_compositions
    # The TreeWidgetItem that is root of all the task items
    attr_reader :root_tasks

    def initialize(parent = nil)
        super

        @root_services = Qt::TreeWidgetItem.new(self)
        root_services.set_text(0, "Data Services")
        @root_compositions = Qt::TreeWidgetItem.new(self)
        root_compositions.set_text(0, "Compositions")
        @root_tasks = Qt::TreeWidgetItem.new(self)
        root_tasks.set_text(0, "Task Contexts")
        set_header_label("")
    end

    ITEM_ROLE_MODEL = Qt::UserRole

    ROOT_ROLE_SERVICE = 0
    ROOT_ROLE_COMPOSITION = 1
    ROOT_ROLE_TASK = 2

    def filter_nil_names(set)
        set.delete_if do |obj|
            if !obj.name
                puts "#{obj.short_name} does not have a name"
                puts "defined at #{Roby.filter_backtrace(obj.definition_location).join("\n  ")}"
                true
            end
        end
    end

    def populate
        services = Syskit::DataService.each_submodel.to_a
        filter_nil_names(services)
        services.sort_by { |srv| srv.name }.each do |srv|
            services << srv
            name = srv.name

            item = Qt::TreeWidgetItem.new(root_services)
            item.set_text(0, name)
            item.set_data(0, ITEM_ROLE_MODEL, Qt::Variant.from_ruby(srv))
        end

        compositions = Syskit::Composition.each_submodel.to_a
        filter_nil_names(compositions)
        compositions.sort_by { |srv| srv.name }.each do |cmp|
            next if cmp.is_specialization?
            name = cmp.name

            has_errors = false

            item = Qt::TreeWidgetItem.new(root_compositions)
            item.set_text(0, name)
            item.set_data(0, ITEM_ROLE_MODEL, Qt::Variant.from_ruby(cmp))
            if has_errors
                item.set_background(0, Qt::Brush.new(Qt::Color.new(255, 128, 128)))
            end
        end

        task_contexts = Syskit::TaskContext.each_submodel.to_a
        filter_nil_names(task_contexts)
        task_contexts.sort_by(&:name).each do |task|
            item = Qt::TreeWidgetItem.new(root_tasks)
            item.set_text(0, task.short_name)
            item.set_data(0, ITEM_ROLE_MODEL, Qt::Variant.from_ruby(task))
        end
    end

    def clear
        @root_services.clear
        @root_compositions.clear
        @root_tasks.clear
    end
end

# Qt::Internal::setDebug(Qt::QtDebugChannel::QTDB_VIRTUAL)
# Qt::Internal::setDebug(Qt::QtDebugChannel::QTDB_GC)

class ModelDisplayView < Ui::StackedDisplay
    attr_reader :specializations
    attr_reader :current_model

    def initialize(parent = nil)
        super(parent)
        @specializations = Hash.new
    end

    def clickedSpecialization(obj_as_variant)
        object = obj_as_variant.to_ruby
        if !specializations.values.include?(object)
            return
        end

        clicked  = object.model.applied_specializations.dup.to_set
        selected = current_model.applied_specializations.dup.to_set

        if clicked.all? { |s| selected.include?(s) }
            # This specialization is already selected, remove it
            clicked.each { |s| selected.delete(s) }
            new_selection = selected

            new_merged_selection = new_selection.inject(Syskit::Models::CompositionSpecialization.new) do |merged, s|
                merged.merge(s)
            end
        else
            # This is not already selected, add it to the set. We have to
            # take care that some of the currently selected specializations
            # might not be compatible
            new_selection = clicked
            new_merged_selection = new_selection.inject(Syskit::Models::CompositionSpecialization.new) do |merged, s|
                merged.merge(s)
            end

            selected.each do |s|
                if new_merged_selection.compatible_with?(s)
                    new_selection << s
                    new_merged_selection.merge(s)
                end
            end
        end

        new_model = current_model.root_model.specializations.create_specialized_model(new_merged_selection, new_selection)
        render_model(new_model)
    end
    slots 'clickedSpecialization(QVariant&)'

    def clear
        super
        specializations.clear
    end

    def render_specialization_graph(root_model)
        plan = Roby::Plan.new
        specializations = Hash.new
        root_model.specializations.each_specialization.map do |spec|
            task_model = root_model.specializations.create_specialized_model(spec, [spec])
            plan.add(task = task_model.new)
            specializations[spec] = task
        end

        return plan, specializations
    end

    def render_model(model)
        clear
        @current_model = model

        if model <= Syskit::Composition
            plan, @specializations = render_specialization_graph(model.root_model)

            current_specializations, incompatible_specializations = [], Hash.new
            if model.root_model != model
                current_specializations = model.applied_specializations.map { |s| specializations[s] }

                incompatible_specializations = specializations.dup
                incompatible_specializations.delete_if do |spec, task|
                    model.applied_specializations.all? { |applied_spec| applied_spec.compatible_with?(spec) }
                end
            end

            display_options = {
                :accessor => :each_compatible_specialization,
                :dot_edge_mark => '--',
                :dot_graph_type => 'graph',
                :graphviz_tool => 'fdp',
                :highlights => current_specializations,
                :toned_down => incompatible_specializations.values
            }
            plan_display = push_plan('Specializations', 'relation_to_dot',
                      plan, Roby.syskit_engine,
                      display_options)
            Qt::Object.connect(plan_display, SIGNAL('selectedObject(QVariant&,QPoint&)'),
                               self, SLOT('clickedSpecialization(QVariant&)'))

            if specializations.empty?
                self.set_item_enabled(count - 1, false)
            end
        end

        main_plan = Roby::Plan.new
        requirements = Syskit::InstanceRequirements.new([model])
        task = requirements.instanciate(
            main_plan,
            Syskit::DependencyInjectionContext.new)
        main_plan.add(task)

        if model <= Syskit::Component
            push_plan('Task Dependency Hierarchy', 'hierarchy', main_plan, Roby.syskit_engine, Hash.new)
            default_widget = push_plan('Dataflow', 'dataflow', main_plan, Roby.syskit_engine, Hash.new)

        else
            default_widget = push_plan('Interface', 'dataflow', main_plan, Roby.syskit_engine, Hash.new)
        end

        services = []
        task.model.each_data_service.sort_by(&:first).each do |service_name, service|
            model_hierarchy = service.model.ancestors.
                find_all do |m|
                    m.kind_of?(Syskit::Models::DataServiceModel) &&
                        m != Syskit::DataService &&
                        m != Syskit::Device &&
                        m != task.model
                end

            services << service_name
            model_hierarchy.each do |m|
                port_mappings = service.port_mappings_for(m).dup
                port_mappings.delete_if do |from, to|
                    from == to
                end
                model_name = m.short_name.gsub("DataServices::", "")
                if !port_mappings.empty?
                    services << "    #{model_name} with port mappings #{port_mappings}"
                else
                    services << "    #{model_name}"
                end
            end
        end
        label = Qt::Label.new(services.join("\n"), self)
        label.background_role = Qt::Palette::NoRole
        push("Provided Services", label)

        self.current_widget = default_widget
    end
end

class SystemModelBrowser < Qt::Widget
    attr_reader :current_model
    attr_reader :model_display

    def initialize(main = nil)
        super

        main_layout = Qt::VBoxLayout.new(self)

        menu_layout = Qt::HBoxLayout.new
        main_layout.add_layout(menu_layout)
        menu_layout.add_stretch(1)

        layout = Qt::HBoxLayout.new
        main_layout.add_layout(layout)
        splitter = Qt::Splitter.new(self)
        layout.add_widget(splitter)
        model_list = ModelListWidget.new(splitter)
        splitter.add_widget(model_list)
        @model_display = ModelDisplayView.new(splitter)
        splitter.add_widget(model_display)
        splitter.set_stretch_factor(1, 2)

        model_list.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, col|
            model = item.data(col, ModelListWidget::ITEM_ROLE_MODEL)
            if model.valid?
                @current_model = model.to_ruby
                render_current_model
            end
        end
        model_list.populate
    end

    def render_current_model
        model_display.render_model(current_model)
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
            require file
        end
    end

    Roby.app.syskit_engine.prepare

    main = SystemModelBrowser.new
    main.resize(800, 500)
    main.show

    $qApp.exec

    # # Do compute the automatic connections
    # Roby.app.orocos_system_model.each_composition do |c|
    #     c.compute_autoconnection
    # end
end
