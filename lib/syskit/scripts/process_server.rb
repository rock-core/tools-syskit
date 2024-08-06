# frozen_string_literal: true

require "roby"
require "syskit/process_managers/remote/server"

require "optparse"

options = Hash[host: "localhost"]
parser = OptionParser.new do |opt|
    opt.on "--fd=FD", Integer, "the socket that should be used as TCP server" do |fd|
        options[:fd] = fd
    end
    opt.on "--log-dir=DIR", String, "the directory that should be used for logs" do |dir|
        Roby.app.log_dir = dir
    end
    opt.on("--debug", "turn on debug mode") do
        Syskit::ProcessManagers::Remote::Server.logger.level = Logger::DEBUG
    end
end

server_port = Syskit::ProcessManagers::Remote::DEFAULT_PORT
Roby::Application.host_options(parser, options)
parser.parse(ARGV)

server = Syskit::ProcessManagers::Remote::Server::Server.new(
    Roby.app, port: server_port, name_service_ip: options[:host]
)
server.open(fd: options[:fd])
server.listen
