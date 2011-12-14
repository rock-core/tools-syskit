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
        Roby.app.orocos_system_model.each_data_service do |srv|
            name = srv.name.gsub(/.*DataServices::/, '')
            model_name_to_object[name] = srv

            item = Qt::TreeWidgetItem.new(root_services)
            item.set_text(0, name)
            item.set_data(0, Qt::UserRole, Qt::Variant.new(0))
        end
        Roby.app.orocos_system_model.each_composition do |cmp|
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
    display = Ui::PlanDisplay.new(splitter)
    splitter.add_widget(display.view)
    splitter.set_stretch_factor(1, 2)

    model_list.connect(SIGNAL('itemClicked(QTreeWidgetItem*,int)')) do |item, col|
        if model = model_list.model_name_to_object[item.text(0)]
            Roby.plan.clear
            requirements = Orocos::RobyPlugin::Engine.create_instanciated_component(Roby.app.orocos_engine, "", model)
            task = requirements.instanciate(Roby.app.orocos_engine, Orocos::RobyPlugin::DependencyInjectionContext.new)
            Roby.plan.add(task)

            task.model.each_data_service do |service_name, service|
                puts service_name
                service.model.ancestors.find_all { |m| m.kind_of?(Orocos::RobyPlugin::DataServiceModel) }.
                    each do |m|
                        puts "  #{m.name} #{service.port_mappings_for(m)}"
                    end
            end
            display_options = Hash.new
            display.update_view(Roby.plan,
                                Roby.app.orocos_engine,
                                display_options)
        end
    end
    model_list.populate
    main.show

    $qApp.exec

    # # Do compute the automatic connections
    # Roby.app.orocos_system_model.each_composition do |c|
    #     c.compute_autoconnection
    # end
end
