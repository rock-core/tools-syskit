require 'roby'
require 'orocos/roby/scripts/common'
require 'roby/schedulers/temporal'
Scripts = Orocos::RobyPlugin::Scripts

dry_run = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/run [options] deployment [additional_things_to_run]\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
    opt.on('--dry-run', "do not configure and start any module") do
        dry_run = true
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
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
                service_name = Scripts.resolve_service_name(service_name)
                Roby.app.orocos_engine.add_mission(service_name)
            end
            Roby.app.orocos_engine.dry_run = dry_run
            Roby.app.orocos_engine.resolve
            if !Roby.engine.scheduler
                require 'roby/schedulers/basic'
                Roby.engine.scheduler = Roby::Schedulers::Temporal.new
            end

            tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::Component).
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

