require 'roby'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

dry_run = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate [options] deployment\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
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

error = Scripts.run do
    Roby.app.run do
        Roby.execute do
            if deployment_file != '-'
                Roby.app.load_orocos_deployment(deployment_file)
            end
            additional_services.each do |service_name|
                Roby.app.orocos_engine.add_mission(service_name)
            end
            Roby.app.orocos_engine.dry_run = dry_run
            Roby.app.orocos_engine.resolve
            if !Roby.engine.scheduler
                require 'roby/schedulers/basic'
                Roby.engine.scheduler = Roby::Schedulers::Basic.new
            end

            tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::Component).
                roots(Roby::TaskStructure::Hierarchy).to_value_set
            tasks.each do |t|
                puts "#{t}: #{t.execution_agent} #{t.each_executed_task.to_a}"
                Roby.plan.add_mission(t)
            end
            tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::Deployment)
            tasks.each do |t|
                puts "#{t}: #{t.execution_agent} #{t.each_executed_task.to_a}"
            end
        end
    end
end

if error
    exit(1)
end

