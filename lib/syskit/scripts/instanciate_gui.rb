require 'roby'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

require 'nokogiri'
require 'Qt4'

require 'orocos/roby/gui/orocos_system_builder'

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
        Roby.app.filter_backtraces = !debug
        if debug
            Orocos::RobyPlugin::SystemModel.logger = Logger.new(STDOUT)
            Orocos::RobyPlugin::SystemModel.logger.formatter = Roby.logger.formatter
            Orocos::RobyPlugin::SystemModel.logger.level = Logger::DEBUG
            Orocos::RobyPlugin::Engine.logger = Logger.new(STDOUT)
            Orocos::RobyPlugin::Engine.logger.formatter = Roby.logger.formatter
            Orocos::RobyPlugin::Engine.logger.level = Logger::DEBUG
        end

        Roby.app.using_plugins 'orocos'
        Roby.app.setup
        toc = Time.now
        STDERR.puts "loaded Roby application in %.3f seconds" % [toc - tic]

        Dir.chdir(APP_DIR)
        Roby.app.setup_global_singletons
        Roby.app.setup_drb_server

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

    ensure Roby.app.stop_process_servers
    end
end

