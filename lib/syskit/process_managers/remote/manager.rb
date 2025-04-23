# frozen_string_literal: true

module Syskit
    module ProcessManagers
        # The remote process manager allows to manage orogen-created deployments managed
        # by a Syskit process server
        #
        # The syskit process servers are started with `syskit process-server`. Even
        # local orogen processes are managed this way, through a syskit-started local
        # process server
        #
        # @see Configuration#use_deployment DeploymentGroup#use_deployment
        module Remote
            # Type transferred between the server and the manager to report on log updates
            #
            # Defined here to make sure it is actually defined. Otherwise, the log
            # state reporting would fail at runtime, and unit-testing for this is
            # very hard.
            LogUploadState = RobyApp::LogTransferServer::LogUploadState

            # Syskit-side interface to the remote process server
            class Manager
                # Emitted when an operation fails
                class Failed < RuntimeError; end
                class StartupFailed < RuntimeError; end

                # The loader object that allows to access models from the remote server
                # @return [Loader]
                attr_reader :loader
                # The root loader object
                # @return [OroGen::Loaders::Base]
                attr_reader :root_loader

                # Mapping from orogen project names to the corresponding content of the
                # orogen files. These projects are the ones available to the remote
                # process server
                attr_reader :available_projects
                # Mapping from deployment names to the corresponding orogen project
                # name. It lists the deployments that are available on the remote
                # process server.
                attr_reader :available_deployments
                # Mapping from deployment names to the corresponding XML type registry
                # for the typekits available on the process server
                attr_reader :available_typekits
                # Mapping from a deployment name to the corresponding {Process}
                # instance, for processes that have been started by this client.
                attr_reader :processes

                # The hostname we are connected to
                attr_reader :host
                # The port on which we are connected on +hostname+
                attr_accessor :port
                # The PID of the server process
                attr_reader :server_pid
                # A string that allows to uniquely identify this process server
                attr_reader :host_id

                def to_s
                    "#<#{self.class} #{host}:#{port}>"
                end

                def inspect
                    to_s
                end

                STATE_CONNECTED = "connected"
                STATE_DISCONNECTED = "disconnected"

                def available?
                    @state == STATE_CONNECTED
                end

                # Connects to the process server at +host+:+port+
                #
                # @option options [OroGen::Loaders::Base] :root_loader
                #   (Orocos.default_loader). The loader object that should be used as
                #   root for this client's loader
                def initialize(
                    host = "localhost", port = DEFAULT_PORT,
                    initial_connection_timeout:
                        Syskit.conf.remote_process_managers_initial_connection_timeout,
                    connection_timeout:
                        Syskit.conf.remote_process_managers_connection_timeout,
                    response_timeout:
                        Syskit.conf.remote_process_managers_response_timeout,
                    root_loader: Orocos.default_loader,
                    register_on_name_server: true,
                    connect_executor: :io
                )
                    @host = host
                    @port = port
                    @state = STATE_DISCONNECTED
                    @response_timeout = response_timeout

                    @processes = {}
                    @death_queue = []
                    @host_id = "#{host}:#{port}:#{server_pid}"
                    @register_on_name_server = register_on_name_server
                    @root_loader = root_loader

                    @connection_timeout = connection_timeout
                    @connect_executor = connect_executor

                    # For now, make the first connection attempt
                    perform_initial_connection(
                        deadline: Roby.monotonic_time + initial_connection_timeout
                    )

                    if !Syskit.conf.remote_process_managers_accept_failed_connections? &&
                       !available?
                        raise ComError,
                              "connection to #{self} failed and " \
                              "remote_process_managers_accept_failed_connections is false"
                    end
                end

                def perform_initial_connection(deadline:)
                    while deadline > Roby.monotonic_time
                        attempt_connection.result(@connection_timeout + @response_timeout)
                        poll
                        break if available?

                        sleep 0.1
                    end
                end

                def connect
                    socket = Socket.tcp(
                        host, port, connect_timeout: @connection_timeout
                    )
                    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                    socket.fcntl(Fcntl::FD_CLOEXEC, 1)
                    socket
                end

                def poll
                    case @state
                    when STATE_DISCONNECTED
                        poll_in_disconnected_state
                    end
                end

                def poll_in_disconnected_state
                    if @connect_future
                        return unless (result = @connect_future.result(0))

                        @connect_future = nil
                        _, socket, error = result
                        return handle_new_connection(socket) if socket

                        ProcessManagers.warn(
                            "failed to connect to remote process manager #{self}: " \
                            "#{error.message}"
                        )
                        schedule_connection_attempt
                    elsif Roby.monotonic_time > @next_connection_deadline
                        attempt_connection
                    end
                end

                def schedule_connection_attempt
                    @next_connection_deadline = Roby.monotonic_time
                end

                def attempt_connection
                    @connect_future = Concurrent::Promises.future_on(@connect_executor) do
                        connect
                    end
                end

                def handle_new_connection(socket)
                    @socket = socket
                    @state = STATE_CONNECTED

                    @server_pid = pid
                    @loader = Loader.new(self, @root_loader)

                    create_log_dir(
                        Roby.app.time_tag, { "parent" => Roby.app.app_metadata }
                    )
                    kill_all if Syskit.conf.kill_all_on_process_server_connection?

                    ProcessManagers.info "connected to remote process manager #{self}"
                rescue StandardError => e
                    ProcessManagers.warn(
                        "got a socket to remote process manager #{self}, but the first " \
                        "call failed: #{e.message}"
                    )

                    close
                    schedule_connection_attempt
                end

                def pid
                    return @server_pid if @server_pid

                    deadline = compute_response_deadline
                    write_command(COMMAND_GET_PID, deadline: deadline)
                    data = read_object(deadline: deadline)
                    @server_pid = Integer(data.first)
                end

                def info
                    deadline = compute_response_deadline
                    write_command(COMMAND_GET_INFO, deadline: deadline)
                    read_object(deadline: deadline)
                end

                # Starts the given deployment on the remote server, without waiting for
                # it to be ready.
                #
                # Returns a {Process} instance that represents the process on the
                # remote side.
                #
                # Raises Failed if the server reports a startup failure
                def start(process_name, deployment, name_mappings = {}, options = {})
                    validate_available

                    if processes[process_name]
                        raise ArgumentError,
                              "this client already started a process " \
                              "called #{process_name}"
                    end

                    if deployment.respond_to?(:to_str)
                        deployment_model =
                            loader.root_loader.deployment_model_from_name(deployment)
                        unless loader.has_deployment?(deployment)
                            raise OroGen::DeploymentModelNotFound,
                                  "deployment #{deployment} exists locally but not " \
                                  "on the remote process server #{self}"
                        end
                    else
                        deployment_model = deployment
                    end

                    prefix_mappings = Orocos::ProcessBase.resolve_prefix(
                        deployment_model, options.delete(:prefix)
                    )
                    name_mappings = prefix_mappings.merge(name_mappings)
                    options[:register_on_name_server] =
                        options.fetch(:register_on_name_server, @register_on_name_server)

                    write_command(
                        COMMAND_START,
                        [process_name, deployment_model.name, name_mappings, options]
                    )

                    deadline = compute_response_deadline
                    wait_for_ack(
                        allowed_replies: [RET_STARTED_PROCESS], deadline: deadline
                    ) do |_pid_s|
                        pid = read_object(deadline: deadline)
                        process = Process.new(
                            process_name, deployment_model, self, pid
                        )
                        name_mappings.each { |a, b| process.map_name(a, b) }
                        processes[process_name] = process
                        return process
                    end
                end

                # Creates a new log dir, and save the given time tag in it (used later
                # on by save_log_dir)
                def create_log_dir(time_tag, metadata = {})
                    write_command(COMMAND_CREATE_LOG, [time_tag, metadata])
                    wait_for_ack
                end

                def queue_death_announcement(deadline:)
                    @death_queue.push(read_object(deadline: deadline))
                end

                # Initiate the upload of a file from the remote process server
                #
                # The transfer is asynchronous, use {#upload_state} to track the
                # upload progress
                def log_upload_file(
                    host, port, certificate, user, password, localfile,
                    max_upload_rate: Float::INFINITY,
                    implicit_ftps: Runtime::Server.use_implicit_ftps?
                )
                    write_command(
                        COMMAND_LOG_UPLOAD_FILE,
                        [host, port, certificate, user, password, localfile,
                         max_upload_rate, implicit_ftps]
                    )

                    wait_for_ack
                end

                # Query the current state of log upload
                #
                # @return [UploadState]
                def log_upload_state
                    write_command(COMMAND_LOG_UPLOAD_STATE)

                    deadline = compute_response_deadline
                    wait_for_ack
                    read_object(deadline: deadline)
                end

                # Wait for some data to be available on the socket
                #
                # This is really meant for unit tests. Do not use in live code.
                def wait_readable
                    select([@socket], [], [], @response_timeout)
                end

                # Waits for processes to terminate. +timeout+ is the number of
                # milliseconds we should wait. If set to nil, the call will block until
                # a process terminates
                #
                # Returns a hash that maps deployment names to the Process::Status
                # object that represents their exit status.
                def wait_termination
                    read_pending_death_announcements

                    result = {}
                    @death_queue.each do |name, status|
                        Process.debug "process #{name} died on remote #{self}"
                        if (p = processes.delete(name))
                            p.dead!
                            result[p] = status
                        else
                            Process.warn "process server reported the exit " \
                                         "of '#{name}', but no process with " \
                                         "that name is registered"
                        end
                    end
                    @death_queue.clear

                    result
                end

                def read_pending_death_announcements
                    loop do
                        begin
                            data = @socket.read_nonblock(1)
                        rescue IO::WaitReadable
                            return
                        end

                        unless data # remote closed, probably a crash
                            raise ComError, "communication to process server closed"
                        end

                        if data != EVENT_DEAD_PROCESS
                            raise "unexpected message #{data} from process server"
                        end

                        deadline = compute_response_deadline
                        queue_death_announcement(deadline: deadline)
                    end
                end

                # Requests to stop the given deployment
                #
                # The call does not block until the process has quit. You will have to
                # call #wait_termination to wait for the process end.
                def stop(deployment_name, hard: false)
                    write_command(COMMAND_END, [deployment_name, hard])
                    wait_for_ack
                end

                def kill_all(hard: true)
                    write_command(COMMAND_KILL_ALL, [hard])

                    deadline = compute_response_deadline
                    wait_for_ack(deadline: deadline)
                    read_object(deadline: deadline)
                end

                def wait_running(*process_names)
                    write_command(COMMAND_WAIT_RUNNING, process_names)

                    deadline = Roby.monotonic_time + @response_timeout
                    wait_for_ack(deadline: deadline) do
                        return read_object(deadline: deadline)
                    end
                end

                def join(deployment_name)
                    process = processes[deployment_name]
                    return unless process

                    loop do
                        result = wait_termination
                        return if result[process]
                    end
                end

                def quit_server
                    write_command(COMMAND_QUIT)
                end

                def disconnect
                    close
                end

                def close
                    @state = STATE_DISCONNECTED
                    @socket.close
                end

                def write_command(cmd, args = nil)
                    validate_available

                    @socket.write_nonblock(cmd)
                    @socket.write_nonblock(Marshal.dump(args)) if args
                end

                def read_object(deadline:)
                    validate_available

                    # This is no guarantee that Marshal.load won't block. Be careful
                    timeout = [0, deadline - Roby.monotonic_time].max
                    unless select([@socket], [], [], timeout)
                        raise TimeoutError,
                              "timed out while waiting for object from #{self} " \
                              "(timeout=#{timeout})"
                    end

                    Marshal.load(@socket)
                end

                class TimeoutError < RuntimeError; end
                class ComError < RuntimeError; end

                def wait_for_answer(deadline: Roby.monotonic + timeout)
                    validate_available

                    loop do
                        reply = begin
                            @socket.read_nonblock(1)
                        rescue IO::WaitReadable
                            timeout = [0, deadline - Roby.monotonic_time].max
                            select([@socket], [], [], timeout)
                            retry
                        end

                        if !reply
                            raise ComError,
                                  "failed to read from process server #{self}, " \
                                  "connection closed"
                        elsif reply == EVENT_DEAD_PROCESS
                            queue_death_announcement(deadline: deadline)
                        else
                            return yield(reply)
                        end
                    end
                end

                def wait_for_ack(
                    allowed_replies: [RET_YES], deadline: compute_response_deadline
                )
                    wait_for_answer(deadline: deadline) do |reply|
                        if reply == RET_NO
                            msg = read_object(deadline: deadline)
                            raise Failed, "failed command: #{msg}"
                        elsif !allowed_replies.include?(reply)
                            raise InternalError, "unexpected reply #{reply}"
                        end

                        if block_given?
                            yield(reply)
                        else
                            true
                        end
                    end
                end

                # Exception raised when attempting an operation on that requires an
                # available process manager and the manager is not available
                class Unavailable < RuntimeError; end

                def validate_available
                    return if available?

                    raise Unavailable,
                          "process server #{self} is currently not available"
                end

                def compute_response_deadline
                    Roby.monotonic_time + @response_timeout
                end
            end
        end
    end
end
