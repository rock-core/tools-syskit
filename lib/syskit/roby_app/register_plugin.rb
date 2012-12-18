require 'syskit/roby_app/plugin'
Roby::Application.register_plugin('syskit', Syskit::RobyApp::Plugin) do
    require 'syskit'
    Syskit::RobyApp::Plugin.enable
end


