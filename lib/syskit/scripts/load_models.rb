require 'roby/standalone'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: scripts/orocos/load_models [robot_name]
Verifies that all the models referred to by robot_name load fine
    EOD

    opt.on_tail('-h', '--help', 'this help message') do
	STDERR.puts opt
	exit
    end
end

robot_name = parser.parse(ARGV)
if !robot_name.empty?
    Roby.app.robot(robot_name.first)
end

Orocos::RobyPlugin.logger.level = Logger::INFO
Roby.filter_backtrace do
    Roby.app.setup
end
STDERR.puts "all models load fine"



