require 'roby'
require 'orocos'
require 'orocos/remote_processes'
require 'orocos/remote_processes/server'

require 'optparse'

options = Hash[host: 'localhost']
parser = OptionParser.new
server_port = Orocos::RemoteProcesses::DEFAULT_PORT
Roby::Application.host_options(parser, options)
parser.parse(ARGV)

Orocos::CORBA.name_service.ip = options[:host]
Orocos::RemoteProcesses::Server.run(Orocos::RemoteProcesses::Server::DEFAULT_OPTIONS, server_port)


