require 'roby'
require 'orocos'
require 'orocos/remote_processes'
require 'orocos/remote_processes/server'

require 'optparse'

options = Hash[host: 'localhost']
parser = OptionParser.new do |opt|
    opt.on '--fd=FD', Integer, "the socket that should be used as TCP server" do |fd|
        options[:fd] = fd
    end
    opt.on '--log-dir=DIR', String, 'the directory that should be used for logs' do |dir|
        Roby.app.log_dir = dir
    end
    opt.on('--debug', 'turn on debug mode') do
        Orocos.logger.level = Logger::DEBUG
    end
end

server_port = Orocos::RemoteProcesses::DEFAULT_PORT
Roby::Application.host_options(parser, options)
parser.parse(ARGV)

class ProcessServer < Orocos::RemoteProcesses::Server
    attr_reader :app
    def initialize(app, port: Orocos::RemoteProcesses::Server::DEFAULT_PORT)
        @app = app
        super(wait: false, output: "%m-%p.txt")
    end

    def open(fd: nil)
        if fd
            server = TCPServer.for_fd(fd)
        else
            server = TCPServer.new(nil, required_port)
        end

        server.fcntl(Fcntl::FD_CLOEXEC, 1)
        @port = server.addr[1]

        com_r, com_w = IO.pipe
        @all_ios.clear
        @all_ios << server << com_r

        trap 'SIGCHLD' do
            com_w.write INTERNAL_SIGCHLD_TRIGGERED
        end
    end

    def create_log_dir(log_dir, time_tag, metadata = Hash.new)
        if log_dir
            app.log_base_dir = log_dir
        end
        if parent_info = metadata['parent']
            if app_name = parent_info['app_name']
                app.app_name = app_name
            end
            if robot_name = parent_info['robot_name']
                app.robot(robot_name, parent_info['robot_type'] || robot_name)
            end
        end

        app.add_app_metadata(metadata)
        app.find_and_create_log_dir(time_tag)
        if parent_info = metadata['parent']
            Robot.info "created #{app.log_dir} on behalf of"
            YAML.dump(parent_info).each_line do |line|
                Robot.info "  #{line.chomp}"
            end
        else
            Robot.info "created #{app.log_dir}"
        end
    end

    def start_process(name, deployment_name, name_mappings, options)
        options = Hash[working_directory: app.log_dir].merge(options)
        super(name, deployment_name, name_mappings, options)
    end
end

Orocos::CORBA.name_service.ip = options[:host]
Orocos.disable_sigchld_handler = true
Orocos.initialize
server = ProcessServer.new(Roby.app, port: server_port)
server.open(fd: options[:fd])
server.listen

