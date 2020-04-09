# frozen_string_literal: true

require "syskit"
Roby::Application.register_plugin("syskit", Syskit::RobyApp::Plugin) do
    require "syskit/shell_interface"
    Syskit::RobyApp::Plugin.enable
end
