require 'roby'
require 'syskit/scripts/common'
require 'roby/schedulers/temporal'
Scripts = Syskit::Scripts

dry_run = false
run_roby = false
parser = OptionParser.new do |opt|
    opt.banner =
"usage: run [options] -r robot_name [actions_to_run]
        run -r robot_name[:robot_type] -c"
    opt.on('-c', 'run the Roby controller for the specified robot') do
        run_roby = true
    end
    opt.on('-h', '--help', 'show this help message') do
        puts parser
        exit(0)
    end
end

Scripts.common_options(parser, false)
remaining = parser.parse(ARGV)

if run_roby
    ARGV.clear
    ARGV << Roby.app.robot_name
    ARGV << Roby.app.robot_type
    require 'roby/app/scripts/run'
    exit 0
end

Roby.app.public_shell_interface = true
Roby.app.public_logs = true

Scripts.tic
error = Scripts.run do
    Roby.app.run do
        Scripts.toc_tic "fully initialized in %.3f seconds"
        Roby.execute do
            remaining.each do |action_name|
                Robot.send("#{action_name}!")
            end
        end
    end
end

if error
    exit(1)
end

