require 'roby'
require 'syskit/scripts/common'

Roby.app.using_plugins 'syskit'
Roby.app.base_setup

include Syskit::Scripts::SingleFileDSL
ARGV.delete_if do |arg|
    arg = File.expand_path(arg)
    if File.file?(arg)
        require arg
        true
    end
end

Roby.once do
    permanent_requirements.each do |req|
        Roby.plan.add_mission(t = req.as_plan)
    end
end

require 'roby/app/scripts/run'
exit 0
