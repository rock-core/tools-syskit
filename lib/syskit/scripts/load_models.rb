require 'roby/standalone'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: scripts/orocos/load_models [options]
Loads model files to check if there is no errors in them
    EOD

    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name whose models should be loaded') do |name|
        robot_name, robot_type = name.split(',')
        Roby.app.robot(name, robot_type||robot_name)
    end

    opt.on_tail('-h', '--help', 'this help message') do
	STDERR.puts opt
	exit
    end
end

Syskit.logger.level = Logger::INFO
error = Roby.display_exception do
    begin
        Roby.app.setup
        Roby.app.orocos_system_model.each_composition do |composition_model|
            puts composition_model
            composition_model.compute_autoconnection
        end
        STDERR.puts "all models load fine"
    ensure Roby.app.stop_process_servers
    end
end
if error
    exit(1)
end

