require 'roby/standalone'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

require 'Qt4'
require 'orocos/roby/gui/orocos_system_builder'

parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate_gui [options] deployments
   'deployment' is either the name of a deployment in config/deployments,
    or a file that should be loaded to get the desired deployment"
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'orocos'
Roby.app.single
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true

error = Scripts.run do
    app  = Qt::Application.new(ARGV)
    main = Qt::Widget.new
    ui = Ui::OrocosSystemBuilderWidget.new(Roby.app.orocos_engine.model, Roby.app.orocos_engine.robot)
    ui.setupUi(main)
    remaining.each do |file|
        STDERR.puts "script: #{file}"
        ui.append(file)
    end
    main.show

    app.exec
end

