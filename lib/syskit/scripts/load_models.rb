require 'roby/standalone'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

if ARGV.size > 0
    Roby.app.robot(*ARGV)
end
Roby.filter_backtrace do
    Roby.app.setup
end
STDERR.puts "all models load fine"



