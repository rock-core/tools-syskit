require 'syskit'
Roby::Application.register_plugin('syskit', Syskit::RobyApp::Plugin) do
    Syskit::RobyApp::Plugin.enable
end


