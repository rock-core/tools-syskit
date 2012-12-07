require 'syskit/roby_app/plugin'
Roby::Application.register_plugin('syskit', Syskit::RobyApp::Plugin) do
    require 'syskit'
    require 'orocos/process_server'

    ::Robot.include Syskit::RobyApp::Robot
    ::Roby::Conf.extend Syskit::RobyApp::Configuration::ConfExtension
    ::Roby.extend Syskit::RobyApp::Toplevel

    Orocos.load_orogen_plugins('syskit')
    Roby.app.filter_out_patterns.push(/^#{Regexp.quote(File.expand_path(File.dirname(__FILE__), ".."))}/)
    Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROGEN_LIB_DIR))
    Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(File.expand_path('..', File.dirname(__FILE__))))
end


