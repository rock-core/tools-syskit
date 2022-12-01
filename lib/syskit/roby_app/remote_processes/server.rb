# frozen_string_literal: true

require "socket"
require "fcntl"
require "net/ftp"
require "orocos"

require "concurrent/atomic/atomic_reference"
require "syskit/roby_app/remote_processes/log_upload_state"
require "syskit/roby_app/remote_processes/ftp_upload"

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

                INTERNAL_QUIT = "Q"
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
                    trap("SIGCHLD", "DEFAULT")
                    @com_w.close
                    @all_ios.each(&:close)
                end

                # Main server loop. This will block and only return when CTRL+C is hit.
                #
                # All started processes are stopped when the server quits
                def listen
                    Server.info "process server listening on port #{port}"
                    server_io, com_r = *@all_ios[0, 2]

                    @quit = false
                    until @quit
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
                                dead_processes = reap_dead_subprocesses
                                announce_dead_processes(dead_processes)
                            elsif cmd == INTERNAL_QUIT
                                next
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

                    Server.info "process server exited normally"
                rescue Interrupt
                    Server.warn "process server exited after SIGINT"
                rescue Exception => e
                    Server.fatal "process server exited because of unhandled exception"
                    Server.fatal "#{e.message} #{e.class}"
                    e.backtrace.each do |line|
                        Server.fatal "  #{line}"
                    end
                ensure
                    quit_and_join
                end

                # Check if a specific subprocess terminated and deregister it
                #
                # @param [Integer] pid the subprocess pid
                # @return [(Orocos::Process,Process::Status),nil] the terminated process
                #   and its exit status if it terminated, nil otherwise
                # @raise Errno::ECHILD if there is no such child with this PID
                def try_wait_for_subprocess_exit(pid)
                    return unless (exited = try_wait_pid(pid))

                    handle_dead_subprocess(*exited)
                end

                # Detect all subprocesses of this server that have died and
                # de-register them
                #
                # @return [Array<(Orocos::Process,Process:Status)>] the list of terminated
                #   subprocesses and their exit status
                def reap_dead_subprocesses
                    dead_processes = []
                    while (exited = try_wait_pid(-1))
                        dead_processes << handle_dead_subprocess(*exited)
                    end
                    dead_processes
                rescue Errno::ECHILD
                    dead_processes
                end

                # Reap a single terminated subprocess if there is one
                #
                # @param [Integer] pid PID of a specific subprocess of interest.
                #   Set to -1 for all subprocesss
                # @return [Proces::Status,nil] the exit status or nil if no
                #   subprocess matching `pid` has finished
                def try_wait_pid(pid)
                    ::Process.wait2(pid, ::Process::WNOHANG)
                end

                # Deregister a dead subprocess from the server
                #
                # @param [Integer] exit_pid the process PID
                # @param [Process::Status] exit_status the process exit status
                # @return [(Orocos::Process,Process::Status)]
                def handle_dead_subprocess(exit_pid, exit_status)
                    process_name, process =
                        processes.find { |_, p| p.pid == exit_pid }
                    return unless process_name

                    process.dead!(exit_status)
                    processes.delete(process_name)

                    [process, exit_status]
                end

                # Announce the end of finished sub-processes to our clients
                #
                # @param [Array<(Orocos::Process,Process::Status)>] the list of
                #   terminated processes
                def announce_dead_processes(dead_processes)
                    dead_processes.each do |process, exit_status|
                        Server.debug "announcing death of #{process.name}"
                        each_client do |socket|
                            Server.debug "  announcing to #{socket}"
                            socket.write(EVENT_DEAD_PROCESS)
                            Marshal.dump([process.name, exit_status], socket)
                        rescue SystemCallError, IOError => e
                            Server.debug "  #{socket}: #{e}"
                        end
                    end
                end

                # Helper method that stops all running processes
                def quit_and_join # :nodoc:
                    @log_upload_command_queue << nil

                    Server.info "stopping process server"
                    processes.each_value do |p|
                        Server.info "killing #{p.name}"
                        # Kill the process hard. If there are still processes,
                        # it means that the normal cleanup procedure did not
                        # work.  Not the time to call stop or whatnot
                        p.kill(false, cleanup: false, hard: true)
                    end

                    each_client do |socket|
                        socket.close
                    rescue SystemCallError, IOError # rubocop:disable Lint/SuppressedException
                    end

                    @log_upload_thread.join
                end

                # Helper method that deals with one client request
                def handle_command(socket) # :nodoc:
                    cmd_code = socket.read(1)
                    return false unless cmd_code

                    if cmd_code == COMMAND_GET_PID
                        Server.debug "#{socket} requested PID"
                        Marshal.dump([::Process.pid], socket)

                    elsif cmd_code == COMMAND_GET_INFO
                        Server.debug "#{socket} requested system information"
                        Marshal.dump(build_system_info, socket)
                    elsif cmd_code == COMMAND_CREATE_LOG
                        Server.debug "#{socket} requested creating a log directory"
                        log_dir, time_tag, metadata = Marshal.load(socket)

                        begin
                            metadata ||= {} # compatible with older clients
                            log_dir = File.expand_path(log_dir) if log_dir
                            create_log_dir(log_dir, time_tag, metadata)
                            socket.write(RET_YES)
                        rescue StandardError => e
                            Server.warn "failed to create log directory #{log_dir}: "\
                                        "#{e.message}"
                            (e.backtrace || []).each do |line|
                                Server.warn "   #{line}"
                            end
                            socket.write(RET_NO)
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
                    elsif cmd_code == COMMAND_KILL_ALL
                        cleanup, hard = Marshal.load(socket)
                        Server.debug "#{socket} requested the end of all processes"
                        processes = kill_all(cleanup: cleanup, hard: hard)
                        dead = join_all(processes)
                        socket.write(RET_YES)
                        ret = dead.map { |dead_p, dead_s| [dead_p.name, dead_s] }
                        socket.write Marshal.dump(ret)
                    elsif cmd_code == COMMAND_QUIT
                        quit
                    elsif cmd_code == COMMAND_LOG_UPLOAD_FILE
                        parameters = Marshal.load(socket)
                        log_upload_file(socket, parameters)
                        socket.write(RET_YES)

                    elsif cmd_code == COMMAND_LOG_UPLOAD_STATE
                        state = log_upload_state
                        socket.write RET_YES
                        socket.write Marshal.dump(state)
                    elsif cmd_code == COMMAND_WAIT_RUNNING
                        result = {}
                        process_names = Marshal.load(socket)
                        process_names.each do |p_name|
                            if (p = @processes[p_name])
                                begin
                                    iors = p.wait_running(0)
                                    result[p_name] = ({ iors: iors } if iors)
                                rescue Orocos::NotFound => e
                                    Server.warn(e.message)
                                    result[p_name] = { error: e.message }
                                rescue Orocos::InvalidIORMessage => e
                                    Server.warn(e.message)
                                    result[p_name] = { error: e.message }
                                end
                            else
                                Server.warn("no process named #{p_name} to wait running")
                                result[p_name] = {
                                    error: "no process named #{p_name} to wait running"
                                }
                            end
                        rescue RuntimeError => e
                            process_names.each do |process_name|
                                result[process_name] ||= { error: e.message }
                            end
                        end
                        socket.write(RET_YES)
                        Marshal.dump(result, socket)
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

                # Kill all running subprocesses
                #
                # This method does not wait for their end, nor does it de-register
                # them.
                #
                # @see join_all announce_dead_processes
                def kill_all(cleanup: false, hard: true)
                    processes.each_value do |p|
                        p.kill(false, cleanup: cleanup, hard: hard)
                    end
                    processes.values
                end

                # Exception raised by {#join_all} when its timeout is reached
                class JoinAllTimeout < RuntimeError; end

                # Wait for the given processes to end
                #
                # @param [Array<Orocos::Process>] processes the subprocess objects
                # @param [Float] poll polling period in seconds
                # @param [Float] timeout timeout after which the method will raise
                #   if there are some of the listed subprocesses still running
                # @return [Array<(Orocos::Process,Process::Status)>]
                def join_all(processes, poll: 0.1, timeout: 10)
                    deadline = Time.now + timeout
                    dead_processes = []
                    until processes.empty?
                        processes.delete_if do |p|
                            if (status = try_wait_for_subprocess_exit(p.pid))
                                dead_processes << status
                                true
                            end
                        end

                        if Time.now > deadline
                            raise JoinAllTimeout,
                                  "timed out while waiting for #{processes.size} "\
                                  "processes to terminate"
                        end
                        sleep poll
                    end
                    dead_processes
                end

                def quit
                    @quit = true
                    @com_w&.write INTERNAL_QUIT
                end

                def log_upload_file(socket, parameters)
                    host, port, certificate, user, password, localfile, max_upload_rate =
                        parameters

                    Server.debug "#{socket} requested uploading of #{localfile}"

                    begin
                        localfile = log_upload_sanitize_path(Pathname(localfile))
                    rescue Exception => e
                        @log_upload_results_queue <<
                            LogUploadState::Result.new(localfile, false, e.message)
                        return
                    end

                    Server.info "queueing upload of #{localfile} to #{host}:#{port}"
                    @log_upload_command_queue <<
                        FTPUpload.new(
                            host, port, certificate,
                            user, password, localfile,
                            max_upload_rate: max_upload_rate || Float::INFINITY
                        )
                end

                def log_upload_sanitize_path(path)
                    log_path = Pathname(app.log_dir)
                    full_path = path.realpath(log_path)
                    if full_path.to_s.start_with?(log_path.to_s + "/")
                        return full_path
                    end

                    raise ArgumentError,
                          "cannot upload files not within the app's log directory"
                end

                def log_upload_main
                    while (transfer = @log_upload_command_queue.pop)
                        @log_upload_current.set(transfer)
                        @log_upload_results_queue << transfer.open_and_transfer
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

                    log_dir = Pathname.new(app.log_dir)
                    results.each do |r|
                        if r.success?
                            r.file = Pathname.new(r.file).relative_path_from(log_dir).to_s
                        end
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
