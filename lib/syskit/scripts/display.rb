require 'roby/standalone'
require 'optparse'
require 'orocos'
require 'syskit'
require 'syskit/roby_app'

Roby.app.using_plugins 'syskit'
Syskit.conf.only_load_models = true

parser = OptionParser.new do |opt|
    opt.on("-r NAME", "--robot NAME",String, "the robot name whose models should be loaded") do |name|
        robot_name, robot_type = name.split(',')
        STDOUT.puts "Loading Robot: #{name}"
        Roby.app.robot(name, robot_type||robot_name)
    end
   

end
parser.parse! ARGV
Roby.app.setup

Syskit.logger.level = Logger::INFO

#laod the displayscript
load 'roby/app/scripts/display.rb'
