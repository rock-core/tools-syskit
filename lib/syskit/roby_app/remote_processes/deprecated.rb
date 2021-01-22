Orocos.warn "orocos/process_server is deprecated."
Orocos.warn "The new class and file layouts are:"
Orocos.warn "require 'orocos/remote_processes'"
Orocos.warn "  Orocos::ProcessClient   renamed to Orocos::RemoteProcesses::Client"
Orocos.warn "  Orocos::RemoteProcess   renamed to Orocos::RemoteProcesses::Process"
Orocos.warn "require 'orocos/remote_processes/server'"
Orocos.warn "  Orocos::ProcessServer   renamed to Orocos::RemoteProcesses::Server"
Orocos.warn "Backtrace"
caller.each do |line|
    Orocos.warn "  #{line}"
end

require 'orocos/remote_processes'
require 'orocos/remote_processes/server'

module Orocos
    ProcessClient = RemoteProcesses::Client
    ProcessServer = RemoteProcesses::Server
    RemoteProcess = RemoteProcesses::Process
end

