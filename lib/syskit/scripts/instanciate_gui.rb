# frozen_string_literal: true

require "roby/standalone"
require "syskit/scripts/common"
Scripts = Syskit::Scripts

require "Qt4"
require "syskit/gui/orocos_system_builder"

parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate_gui [options] deployments
   'deployment' is either the name of a deployment in config/deployments,
    or a file that should be loaded to get the desired deployment"
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using "syskit"
Roby.app.single
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true

error = Scripts.run do
    app  = Qt::Application.new(ARGV)
    main = Qt::Widget.new
    ui = Ui::OrocosSystemBuilderWidget.new(Roby.app.syskit_engine.model, Roby.app.syskit_engine.robot)
    ui.setupUi(main)
    remaining.each do |file|
        STDERR.puts "script: #{file}"
        ui.append(file)
    end
    main.show

    app.exec
end
