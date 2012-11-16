require 'roby'
require 'orocos/roby/scripts/common'
require 'roby/schedulers/temporal'
Scripts = Syskit::Scripts

dry_run = false
run_roby = false
parser = OptionParser.new do |opt|
    opt.banner =
"usage: run [options] deployment [additional_things_to_run]
        run -r robot_name[:robot_type] -c

In the first form, load a deployment file and run it, optionally adding some
more things to the running system (such as devices or definitions). If no
deployment file needs to be loaded (e.g. to run a device), use '-' as the
deployment name. A -rrobot_name option can be given to configure as a specific
robot

In the second form, run the specified Roby controller"
    opt.on('--dry-run', "do not configure and start any module") do
        dry_run = true
    end
    opt.on('-c', 'run the Roby controller for the specified robot') do
        run_roby = true
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

if remaining.empty?
    STDERR.puts parser
    exit(1)
end
deployment_file     = remaining.shift
additional_services = remaining.dup

Roby.app.public_shell_interface = true
Roby.app.public_logs = true

Scripts.tic
error = Scripts.run do
    Roby.app.run do
        Scripts.toc_tic "fully initialized in %.3f seconds"
        Roby.execute do
            if deployment_file != '-'
                Roby.app.load_orocos_deployment(deployment_file)
            end
            additional_services.each do |service_name|
                Scripts.add_service(service_name)
            end
            Roby.app.orocos_engine.dry_run = dry_run
            Roby.app.orocos_engine.resolve
            if !Roby.engine.scheduler
                require 'roby/schedulers/temporal'
                Roby.engine.scheduler = Roby::Schedulers::Temporal.new
            end

            tasks = Roby.plan.find_tasks(Syskit::Component).
                roots(Roby::TaskStructure::Hierarchy).to_value_set
            tasks.each do |t|
                Roby.plan.add_mission(t)
            end
        end
    end
end

if error
    exit(1)
end

