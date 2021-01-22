require 'socket'
require 'fcntl'
module Orocos
    module RemoteProcesses
    # A remote process management server.
    #
    # It allows to start/stop and monitor the status of processes on a
    # client/server way.
    #
    # Use {ProcessClient} to access a server
    class Server
        extend Logger::Root("Orocos::RemoteProcesses::Server", Logger::INFO)

        # Returns a unique directory name as a subdirectory of
        # +base_dir+, based on +path_spec+. The generated name
        # is of the form
        #   <base_dir>/a/b/c/YYYYMMDD-HHMM-basename
        # if <tt>path_spec = "a/b/c/basename"</tt>. A .<number> suffix
        # is appended if the path already exists.
        #
        # Shamelessly taken from Roby
        def self.unique_dirname(base_dir, path_spec, date_tag = nil)
            if path_spec =~ /\/$/
                basename = ""
                dirname = path_spec
            else
                basename = File.basename(path_spec)
                dirname  = File.dirname(path_spec)
            end

            date_tag ||= Time.now.strftime('%Y%m%d-%H%M')
            if basename && !basename.empty?
                basename = date_tag + "-" + basename
            else
                basename = date_tag
            end

            # Check if +basename+ already exists, and if it is the case add a
            # .x suffix to it
            full_path = File.expand_path(File.join(dirname, basename), base_dir)
            base_dir  = File.dirname(full_path)

            unless File.exists?(base_dir)
                FileUtils.mkdir_p(base_dir)
            end

            final_path, i = full_path, 0
            while File.exists?(final_path)
                i += 1
                final_path = full_path + ".#{i}"
            end

            final_path
        end

        DEFAULT_OPTIONS = { :wait => false, :output => '%m-%p.txt' }

        # Start a standalone process server using the given options and port.
        # The options are passed to Server.run when a new deployment is started
        def self.run(options = DEFAULT_OPTIONS, port = DEFAULT_PORT)
            Orocos.disable_sigchld_handler = true
            Orocos.initialize
            new({ :wait => false }.merge(options), port).exec

        rescue Interrupt
        end

        # The startup options to be passed to Orocos.run
        attr_reader :default_start_options
        # The TCP port we are required to bind to
        #
        # It is the port given to {initialize}. In general, it is equal to {port}.
        # Only if it is equal to zero will {port} contain the actual used port
        # as allocated by the operating system
        #
        # @return [Integer]
        attr_reader :required_port
        # The TCP port we are listening to
        #
        # In general, it is equal to {required_port}.  Only if {required_port}
        # is equal to zero will {port} contain the actual used port as allocated
        # by the operating system
        #
        # It is nil until the server socket is created
        #
        # @return [Integer,nil]
        attr_reader :port
        # A mapping from the deployment names to the corresponding Process
        # object.
        attr_reader :processes
        # The object we use to load oroGen models
        #
        # It is commonly an [OroGen::Loaders::PkgConfig] loader object
        # @return [OroGen::Loaders::Base]
        attr_reader :loader

        def self.create_pkgconfig_loader
            OroGen::Loaders::RTT.new(Orocos.orocos_target)
        end

        def initialize(default_start_options = DEFAULT_OPTIONS,
                       port = DEFAULT_PORT,
                       loader = self.class.create_pkgconfig_loader)

            @default_start_options = Kernel.validate_options default_start_options,
                :wait => false,
                :output => '%m-%p.txt'

            @loader = loader
            @required_port = port
            @port = nil
            @processes = Hash.new
            @all_ios = Array.new
        end

        def each_client(&block)
            clients = @all_ios[2..-1]
            if clients
                clients.each(&block)
            end
        end

        def exec
            open
            listen
        end

        INTERNAL_SIGCHLD_TRIGGERED = "S"

        def open
            Server.info "starting on port #{required_port}"
            server = TCPServer.new(nil, required_port)
            server.fcntl(Fcntl::FD_CLOEXEC, 1)
            @port = server.addr[1]

            com_r, com_w = IO.pipe
            @all_ios.clear
            @all_ios << server << com_r

            trap 'SIGCHLD' do
                com_w.write INTERNAL_SIGCHLD_TRIGGERED
            end
        end

        # Main server loop. This will block and only return when CTRL+C is hit.
        #
        # All started processes are stopped when the server quits
        def listen
            Server.info "process server listening on port #{port}"
            server_io, com_r = *@all_ios[0, 2]

            while true
                readable_sockets, _ = select(@all_ios, nil, nil)
                if readable_sockets.include?(server_io)
                    readable_sockets.delete(server_io)
                    client_socket = server_io.accept
                    client_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                    client_socket.fcntl(Fcntl::FD_CLOEXEC, 1)
                    Server.debug "new connection: #{client_socket}"
                    @all_ios << client_socket
                end

                if readable_sockets.include?(com_r)
                    readable_sockets.delete(com_r)
                    cmd = com_r.read(1)
                    if cmd == INTERNAL_SIGCHLD_TRIGGERED
                        process_dead_processes
                    elsif cmd
                        Server.warn "unknown internal communication code #{cmd.inspect}"
                    end
                end

                readable_sockets.each do |socket|
                    if !handle_command(socket)
                        Server.debug "#{socket} closed or errored"
                        socket.close
                        @all_ios.delete(socket)
                    end
                end
            end

        rescue Exception => e
            if e.class == Interrupt # normal procedure
                Server.fatal "process server exited normally"
                return
            end

            Server.fatal "process server exited because of unhandled exception"
            Server.fatal "#{e.message} #{e.class}"
            e.backtrace.each do |line|
                Server.fatal "  #{line}"
            end

        ensure
            quit_and_join
        end

        def process_dead_processes
            while exited = ::Process.wait2(-1, ::Process::WNOHANG)
                pid, exit_status = *exited
                process_name, process = processes.find { |_, p| p.pid == pid }
                next if !process_name

                process.dead!(exit_status)
                processes.delete(process_name)
                Server.debug "announcing death: #{process_name}"
                each_client do |socket|
                    begin
                        Server.debug "  announcing to #{socket}"
                        socket.write(EVENT_DEAD_PROCESS)
                        Marshal.dump([process_name, exit_status], socket)
                    rescue IOError
                        Server.debug "  #{socket}: IOError"
                    end
                end
            end
        rescue Errno::ECHILD
        end

        # Helper method that stops all running processes
        def quit_and_join # :nodoc:
            Server.warn "stopping process server"
            processes.each_value do |p|
                Server.warn "killing #{p.name}"
                p.kill
            end

            each_client do |socket|
                begin socket.close
                rescue IOError
                end
            end
        end

        # Helper method that deals with one client request
        def handle_command(socket) # :nodoc:
            cmd_code = socket.read(1)
            raise EOFError if !cmd_code

            if cmd_code == COMMAND_GET_PID
                Server.debug "#{socket} requested PID"
                Marshal.dump([::Process.pid], socket)

            elsif cmd_code == COMMAND_GET_INFO
                Server.debug "#{socket} requested system information"
                Marshal.dump(build_system_info, socket)
            elsif cmd_code == COMMAND_MOVE_LOG
                Server.debug "#{socket} requested moving a log directory"
                begin
                    log_dir, results_dir = Marshal.load(socket)
                    log_dir = File.expand_path(log_dir)
                    results_dir = File.expand_path(results_dir)
                    move_log_dir(log_dir, results_dir)
                rescue Interrupt
                    raise
                rescue Exception => e
                    Server.warn "failed to move log directory from #{log_dir} to #{results_dir}: #{e.message}"
                    (e.backtrace || Array.new).each do |line|
                        Server.warn "   #{line}"
                    end
                end

            elsif cmd_code == COMMAND_CREATE_LOG
                begin
                    Server.debug "#{socket} requested creating a log directory"
                    log_dir, time_tag, metadata = Marshal.load(socket)
                    metadata ||= Hash.new # compatible with older clients
                    if log_dir
                        log_dir = File.expand_path(log_dir)
                    end
                    create_log_dir(log_dir, time_tag, metadata)
                rescue Interrupt
                    raise
                rescue Exception => e
                    Server.warn "failed to create log directory #{log_dir}: #{e.message}"
                    (e.backtrace || Array.new).each do |line|
                        Server.warn "   #{line}"
                    end
                end

            elsif cmd_code == COMMAND_START
                name, deployment_name, name_mappings, options = Marshal.load(socket)
                options ||= Hash.new
                Server.debug "#{socket} requested startup of #{name} with #{options} and mappings #{name_mappings}"
                begin
                    p = start_process(name, deployment_name, name_mappings, options)
                    Server.debug "#{name}, from #{deployment_name}, is started (#{p.pid})"
                    socket.write(RET_STARTED_PROCESS)
                    Marshal.dump(p.pid, socket)
                rescue Interrupt
                    raise
                rescue Exception => e
                    Server.warn "failed to start #{name}: #{e.message}"
                    (e.backtrace || Array.new).each do |line|
                        Server.warn "   #{line}"
                    end
                    socket.write(RET_NO)
                    socket.write Marshal.dump(e.message)
                end
            elsif cmd_code == COMMAND_END
                name, cleanup, hard = Marshal.load(socket)
                Server.debug "#{socket} requested end of #{name}"
                if (p = processes[name])
                    begin
                        end_process(p, cleanup: cleanup, hard: hard)
                        socket.write(RET_YES)
                    rescue Interrupt
                        raise
                    rescue Exception => e
                        Server.warn "exception raised while calling #{p}#kill(false)"
                        Server.log_pp(:warn, e)
                        socket.write(RET_NO)
                    end
                else
                    Server.warn "no process named #{name} to end"
                    socket.write(RET_NO)
                end
            elsif cmd_code == COMMAND_QUIT
                quit
            end

            true
        rescue Interrupt
            raise
        rescue Exception => e
            Server.fatal "protocol error on #{socket}: #{e}"
            Server.fatal "while serving command #{cmd_code}"
            e.backtrace.each do |bt|
                Server.fatal "  #{bt}"
            end
            false

        rescue EOFError
            false
        end

        def create_log_dir(log_dir, time_tag, metadata = Hash.new)
            log_dir     = File.expand_path(log_dir)
            Server.debug "  #{log_dir}, time: #{time_tag}"
            FileUtils.mkdir_p(log_dir)
            File.open(File.join(log_dir, 'time_tag'), 'w') do |io|
                io.write(time_tag)
            end
            File.open(File.join(log_dir, 'info.yml'), 'w') do |io|
                YAML.dump(Hash['time' => time_tag].merge(metadata), io)
            end
        end

        def move_log_dir(log_dir, results_dir)
            date_tag    = File.read(File.join(log_dir, 'time_tag')).strip
            Server.debug "  #{log_dir} => #{results_dir}"
            if File.directory?(log_dir)
                dirname = Server.unique_dirname(results_dir + '/', '', date_tag)
                FileUtils.mv log_dir, dirname
            end
        end
        
        def build_system_info
            available_projects = Hash.new
            available_typekits = Hash.new
            available_deployments = Hash.new
            loader.each_available_project_name do |name|
                available_projects[name] = loader.project_model_text_from_name(name)
            end
            loader.each_available_typekit_name do |name|
                available_typekits[name] = loader.typekit_model_text_from_name(name)
            end
            loader.each_available_deployment_name do |name|
                available_deployments[name] = loader.find_project_from_deployment_name(name)
            end
            return available_projects, available_deployments, available_typekits
        end

        def start_process(name, deployment_name, name_mappings, options)
            p = Orocos::Process.new(name, deployment_name,
                loader: @loader,
                name_mappings: name_mappings)
            p.spawn(**self.default_start_options.merge(options))
            processes[name] = p
        end

        def end_process(p, cleanup: true, hard: false)
            p.kill(false, cleanup: cleanup, hard: hard)
        end

        def quit
            raise Interrupt
        end
    end
    end
end
