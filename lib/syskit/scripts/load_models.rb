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

Orocos::RobyPlugin.logger.level = Logger::INFO
Roby.filter_backtrace do
    Roby.app.setup
end
STDERR.puts "all models load fine"

