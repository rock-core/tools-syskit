# frozen_string_literal: true

require "socket"
require "fcntl"
require "net/ftp"
require "orocos"

require "concurrent/atomic/atomic_reference"
require "syskit/roby_app/remote_processes/log_upload_state"

module Syskit
    module RobyApp
        module RemoteProcesses
            # A remote process management server.
            #
            # It allows to start/stop and monitor the status of processes on a
            # client/server way.
            #
            # Use {ProcessClient} to access a server
            class Server
                extend Logger::Root(
                    "Syskit::RobyApp::RemoteProcesses::Server", Logger::INFO
                )

                # Returns a unique directory name as a subdirectory of
                # +base_dir+, based on +path_spec+. The generated name
                # is of the form
                #   <base_dir>/a/b/c/YYYYMMDD-HHMM-basename
                # if <tt>path_spec = "a/b/c/basename"</tt>. A .<number> suffix
                # is appended if the path already exists.
                #
                # Shamelessly taken from Roby
                def self.unique_dirname(base_dir, path_spec, date_tag = nil)
                    if path_spec =~ %r{\/$}
                        basename = ""
                        dirname = path_spec
                    else
                        basename = File.basename(path_spec)
                        dirname  = File.dirname(path_spec)
                    end

                    date_tag ||= Time.now.strftime("%Y%m%d-%H%M")
                    basename =
                        if basename && !basename.empty?
                            date_tag + "-" + basename
                        else
                            date_tag
                        end

                    # Check if +basename+ already exists, and if it is the case add a
                    # .x suffix to it
                    full_path = File.expand_path(File.join(dirname, basename), base_dir)
                    base_dir  = File.dirname(full_path)

                    FileUtils.mkdir_p(base_dir) unless File.exist?(base_dir)

                    final_path = full_Path
                    i = 0
                    while File.exist?(final_path)
                        i += 1
                        final_path = full_path + ".#{i}"
                    end

                    final_path
                end

                DEFAULT_OPTIONS = { wait: false, output: "%m-%p.txt" }.freeze

                # Start a standalone process server using the given options and port.
                # The options are passed to Server.run when a new deployment is started
                def self.run(options = DEFAULT_OPTIONS, port = DEFAULT_PORT)
                    Orocos.disable_sigchld_handler = true
                    Orocos.initialize
                    new({ wait: false }.merge(options), port).exec
                rescue Interrupt # rubocop:disable Lint/SuppressedException
                end

                # The underlying Roby::Application object we use to resolve paths
                attr_reader :app
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

                def initialize(
                    app,
                    port: DEFAULT_PORT,
                    loader: self.class.create_pkgconfig_loader
                )
                    @app = app
                    @default_start_options = { wait: false, output: "%m-%p.txt" }

                    @loader = loader
                    @required_port = port
                    @port = nil
                    @processes = {}
                    @all_ios = []
                    @log_upload_current = Concurrent::AtomicReference.new
                    @log_upload_command_queue = Queue.new
                    @log_upload_results_queue = Queue.new
                    @log_upload_thread = Thread.new { log_upload_main }
                end

                def each_client(&block)
                    @all_ios[2..-1]&.each(&block)
                end

                def exec
                    open

                    begin
                        listen
                    ensure
                        close
                    end
                end

                INTERNAL_SIGCHLD_TRIGGERED = "S"

                def open(fd: nil)
                    Server.info "starting on port #{required_port}"

                    server =
                        if fd
                            TCPServer.for_fd(fd)
                        else
                            TCPServer.new(nil, required_port)
                        end

                    server.fcntl(Fcntl::FD_CLOEXEC, 1)
                    @port = server.addr[1]

                    com_r, @com_w = IO.pipe
                    @all_ios.clear
                    @all_ios << server << com_r

                    trap "SIGCHLD" do
                        @com_w.write INTERNAL_SIGCHLD_TRIGGERED
                    end
                end

                def close
                    @com_w.close
                    @all_ios.each(&:close)
                    trap("SIGCHLD", "DEFAULT")
                end

                # Main server loop. This will block and only return when CTRL+C is hit.
                #
                # All started processes are stopped when the server quits
                def listen
                    Server.info "process server listening on port #{port}"
                    server_io, com_r = *@all_ios[0, 2]

                    loop do
                        readable_sockets, = select(@all_ios, nil, nil)
                        if readable_sockets.include?(server_io)
                            readable_sockets.delete(server_io)
                            client_socket = server_io.accept
                            client_socket.setsockopt(
                                Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true
                            )
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
                                Server.warn "unknown internal communication code "\
                                            "#{cmd.inspect}"
                            end
                        end

                        readable_sockets.each do |socket|
                            unless handle_command(socket)
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
                    while (exited = ::Process.wait2(-1, ::Process::WNOHANG))
                        pid, exit_status = *exited
                        process_name, process = processes.find { |_, p| p.pid == pid }
                        next unless process_name

                        process.dead!(exit_status)
                        processes.delete(process_name)
                        Server.debug "announcing death: #{process_name}"
                        each_client do |socket|
                            Server.debug "  announcing to #{socket}"
                            socket.write(EVENT_DEAD_PROCESS)
                            Marshal.dump([process_name, exit_status], socket)
                        rescue IOError
                            Server.debug "  #{socket}: IOError"
                        end
                    end
                rescue Errno::ECHILD # rubocop:disable Lint/SuppressedException
                end

                # Helper method that stops all running processes
                def quit_and_join # :nodoc:
                    Server.warn "stopping process server"
                    processes.each_value do |p|
                        Server.warn "killing #{p.name}"
                        p.kill
                    end

                    each_client do |socket|
                        socket.close
                    rescue IOError # rubocop:disable Lint/SuppressedException
                    end

                    @log_upload_command_queue << nil
                    @log_upload_thread.join
                end

                # Helper method that deals with one client request
                def handle_command(socket) # :nodoc:
                    cmd_code = socket.read(1)
                    raise EOFError unless cmd_code

                    if cmd_code == COMMAND_GET_PID
                        Server.debug "#{socket} requested PID"
                        Marshal.dump([::Process.pid], socket)

                    elsif cmd_code == COMMAND_GET_INFO
                        Server.debug "#{socket} requested system information"
                        Marshal.dump(build_system_info, socket)
                    elsif cmd_code == COMMAND_CREATE_LOG
                        begin
                            Server.debug "#{socket} requested creating a log directory"
                            log_dir, time_tag, metadata = Marshal.load(socket)
                            metadata ||= {} # compatible with older clients
                            log_dir = File.expand_path(log_dir) if log_dir
                            create_log_dir(log_dir, time_tag, metadata)
                        rescue Interrupt
                            raise
                        rescue Exception => e
                            Server.warn "failed to create log directory #{log_dir}: "\
                                        "#{e.message}"
                            (e.backtrace || []).each do |line|
                                Server.warn "   #{line}"
                            end
                        end

                    elsif cmd_code == COMMAND_START
                        name, deployment_name, name_mappings, options =
                            Marshal.load(socket)
                        options ||= {}
                        Server.debug "#{socket} requested startup of #{name} with "\
                                     "#{options} and mappings #{name_mappings}"
                        begin
                            p = start_process(
                                name, deployment_name, name_mappings, options
                            )
                            Server.debug "#{name}, from #{deployment_name}, "\
                                         "is started (#{p.pid})"
                            socket.write(RET_STARTED_PROCESS)
                            Marshal.dump(p.pid, socket)
                        rescue Interrupt
                            raise
                        rescue Exception => e
                            Server.warn "failed to start #{name}: #{e.message}"
                            (e.backtrace || []).each do |line|
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
                                Server.warn "exception raised while calling "\
                                            "#{p}#kill(false)"
                                Server.log_pp(:warn, e)
                                socket.write(RET_NO)
                            end
                        else
                            Server.warn "no process named #{name} to end"
                            socket.write(RET_NO)
                        end
                    elsif cmd_code == COMMAND_QUIT
                        quit
                    elsif cmd_code == COMMAND_LOG_UPLOAD_FILE
                        host, port, certificate, user, password, localfile =
                            Marshal.load(socket)
                        Server.debug "#{socket} requested uploading of #{localfile}"
                        @log_upload_command_queue <<
                            Upload.new(
                                host, port, certificate,
                                user, password, localfile
                            )

                        socket.write(RET_YES)
                    elsif cmd_code == COMMAND_LOG_UPLOAD_STATE
                        state = log_upload_state
                        socket.write RET_YES
                        socket.write Marshal.dump(state)
                    end

                    true
                rescue Interrupt
                    raise
                rescue EOFError
                    false
                rescue Exception => e
                    Server.fatal "protocol error on #{socket}: #{e}"
                    Server.fatal "while serving command #{cmd_code}"
                    e.backtrace.each do |bt|
                        Server.fatal "  #{bt}"
                    end
                    false
                end

                def create_log_dir(log_dir, time_tag, metadata = {})
                    app.log_base_dir = log_dir if log_dir

                    if (parent_info = metadata["parent"])
                        if (app_name = parent_info["app_name"])
                            app.app_name = app_name
                        end
                        if (robot_name = parent_info["robot_name"])
                            app.robot(robot_name, parent_info["robot_type"] || robot_name)
                        end
                    end

                    app.add_app_metadata(metadata)
                    app.find_and_create_log_dir(time_tag)
                    if (parent_info = metadata["parent"])
                        ::Robot.info "created #{app.log_dir} on behalf of"
                        YAML.dump(parent_info).each_line do |line|
                            ::Robot.info "  #{line.chomp}"
                        end
                    else
                        ::Robot.info "created #{app.log_dir}"
                    end
                end

                def build_system_info
                    available_projects = {}
                    available_typekits = {}
                    available_deployments = {}
                    loader.each_available_project_name do |name|
                        available_projects[name] =
                            loader.project_model_text_from_name(name)
                    end
                    loader.each_available_typekit_name do |name|
                        available_typekits[name] =
                            loader.typekit_model_text_from_name(name)
                    end
                    loader.each_available_deployment_name do |name|
                        available_deployments[name] =
                            loader.find_project_from_deployment_name(name)
                    end
                    [available_projects, available_deployments, available_typekits]
                end

                def start_process(name, deployment_name, name_mappings, options)
                    options = Hash[working_directory: app.log_dir].merge(options)

                    p = Orocos::Process.new(
                        name, deployment_name,
                        loader: @loader,
                        name_mappings: name_mappings
                    )
                    p.spawn(**default_start_options.merge(options))
                    processes[name] = p
                end

                def end_process(process, cleanup: true, hard: false)
                    process.kill(false, cleanup: cleanup, hard: hard)
                end

                def quit
                    raise Interrupt
                end

                Upload = Struct.new(
                    :host, :port, :certificate, :user, :password, :file
                ) do
                    def apply
                        Tempfile.create do |cert_io|
                            cert_io.write certificate
                            cert_io.flush

                            Net::FTP.open(
                                host,
                                private_data_connection: false,
                                port: port,
                                ssl: { verify_mode: OpenSSL::SSL::VERIFY_PEER,
                                       ca_file: cert_io.path }
                            ) do |ftp|
                                ftp.login(user, password)
                                File.open(file) do |file_io|
                                    ftp.storbinary("STOR #{File.basename(file)}",
                                                   file_io, Net::FTP::DEFAULT_BLOCKSIZE)
                                end
                            end
                        end
                        LogUploadState::Result.new(file, true, nil)
                    rescue Exception => e
                        LogUploadState::Result.new(file, false, e.message)
                    end
                end

                def log_upload_main
                    while (transfer = @log_upload_command_queue.pop)
                        @log_upload_current.set(transfer)
                        @log_upload_results_queue << transfer.apply
                        @log_upload_current.set(nil)
                    end
                end

                def log_upload_state
                    results = []
                    loop do
                        results << @log_upload_results_queue.pop(true)
                    rescue ThreadError
                        break
                    end

                    # This count is not exact. However, it's designed to show
                    # at least one transfer if there are some. I.e. the only
                    # case where pending == 0 is when there is truly nothing to
                    # be done
                    pending = @log_upload_command_queue.size
                    pending += 1 if @log_upload_current.get
                    LogUploadState.new(pending, results)
                end
            end
        end
    end
end
