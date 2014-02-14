require 'syskit'
Roby::Application.register_plugin('realtime_syskit', Syskit::RobyApp::Plugin) do
#    require 'syskit/shell'
    Syskit::RobyApp::Plugin.enable
end
