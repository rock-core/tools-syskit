require 'roby'
require 'syskit/scripts/common'

Roby.app.using_plugins 'syskit'
Roby.app.base_setup

direct_files = []
ARGV.delete_if do |arg|
    arg = File.expand_path(arg)
    if File.file?(arg)
        direct_files << arg
        true
    end
end

if !direct_files.empty?
    include Syskit::Scripts::SingleFileDSL
end
Roby.app.additional_model_files.concat(direct_files)

if respond_to?(:permanent_requirements)
    Roby.once do
        permanent_requirements.each do |req|
            Roby.plan.add_mission(t = req.as_plan)
        end
    end
end

require 'roby/app/scripts/run'
exit 0
