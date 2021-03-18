# frozen_string_literal: true

require "orocos"
require "syskit/roby_app/remote_processes/loader"

module Syskit
    module RobyApp
        module RemoteProcesses
            # Client-side API to a {Server} instance
            #
            # Process servers allow to start/stop and monitor processes on remote
            # machines. Instances of this class provides access to remote process
            # servers.
            class Client
                # Emitted when an operation fails
                class Failed < RuntimeError; end
                class StartupFailed < RuntimeError; end

                # The socket instance used to communicate with the server
                attr_reader :socket
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
                # Mapping from a deployment name to the corresponding RemoteProcess
                # instance, for processes that have been started by this client.
                attr_reader :processes

                # The hostname we are connected to
                attr_reader :host
                # The port on which we are connected on +hostname+
                attr_reader :port
                # The PID of the server process
                attr_reader :server_pid
                # A string that allows to uniquely identify this process server
                attr_reader :host_id
                # The name service object that allows to resolve tasks from this process
                # server
                attr_reader :name_service

                def to_s
                    "#<Syskit::RobyApp::RemoteProcesses::Client #{host}:#{port}>"
                end

                def inspect
                    to_s
                end

                # Connects to the process server at +host+:+port+
                #
                # @option options [Orocos::NameService] :name_service
                #   (Orocos.name_service). The name service object that should be used
                #   to resolve tasks started by this process server
                # @option options [OroGen::Loaders::Base] :root_loader
                #   (Orocos.default_loader). The loader object that should be used as
                #   root for this client's loader
                def initialize(
                    host = "localhost", port = DEFAULT_PORT,
                    response_timeout: 10, root_loader: Orocos.default_loader,
                    name_service: Orocos.name_service
                )
                    @host = host
                    @port = port
                    @socket =
                        begin TCPSocket.new(host, port)
                        rescue Errno::ECONNREFUSED => e
                            raise e.class,
                                  "cannot contact process server at "\
                                  "'#{host}:#{port}': #{e.message}"
                        end

                    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                    socket.fcntl(Fcntl::FD_CLOEXEC, 1)

                    @name_service = name_service
                    begin
                        @server_pid = pid
                    rescue EOFError
                        raise StartupFailed, "process server failed at '#{host}:#{port}'"
                    end

                    @loader = Loader.new(self, root_loader)
                    @root_loader = loader.root_loader
                    @processes = {}
                    @death_queue = []
                    @host_id = "#{host}:#{port}:#{server_pid}"
                    @response_timeout = response_timeout
                end

                def pid(timeout: @response_timeout)
                    return @server_pid if @server_pid

                    socket.write(COMMAND_GET_PID)
                    unless select([socket], [], [], timeout)
                        raise "timeout while reading process server at '#{host}:#{port}'"
                    end

                    @server_pid = Integer(Marshal.load(socket).first)
                end

                def info(timeout: @response_timeout)
                    socket.write(COMMAND_GET_INFO)
                    unless select([socket], [], [], timeout)
                        raise "timeout while reading process server "\
                              "at '#{host}:#{port}'"
                    end
                    Marshal.load(socket)
                end

                def disconnect
                    socket.close
                end

                class TimeoutError < RuntimeError
                end

                class ComError < RuntimeError
                end

                def wait_for_answer(timeout: @response_timeout)
                    loop do
                        unless select([socket], [], [], timeout)
                            raise TimeoutError,
                                  "reached timeout of #{timeout}s in #wait_for_answer"
                        end

                        unless (reply = socket.read(1))
                            raise ComError,
                                  "failed to read from process server #{self}"
                        end

                        if reply == EVENT_DEAD_PROCESS
                            queue_death_announcement
                        else
                            yield(reply)
                        end
                    end
                end

                def wait_for_ack
                    wait_for_answer do |reply|
                        return true if reply == RET_YES
                        return false if reply == RET_NO

                        raise InternalError, "unexpected reply #{reply}"
                    end
                end

                # Starts the given deployment on the remote server, without waiting for
                # it to be ready.
                #
                # Returns a RemoteProcess instance that represents the process on the
                # remote side.
                #
                # Raises Failed if the server reports a startup failure
                def start(process_name, deployment, name_mappings = {}, options = {})
                    if processes[process_name]
                        raise ArgumentError,
                              "this client already started a process "\
                              "called #{process_name}"
                    end

                    if deployment.respond_to?(:to_str)
                        deployment_model =
                            loader.root_loader.deployment_model_from_name(deployment)
                        unless loader.has_deployment?(deployment)
                            raise OroGen::DeploymentModelNotFound,
                                  "deployment #{deployment} exists locally but not "\
                                  "on the remote process server #{self}"
                        end
                    else deployment_model = deployment
                    end

                    prefix_mappings = Orocos::ProcessBase.resolve_prefix(
                        deployment_model, options.delete(:prefix)
                    )
                    name_mappings = prefix_mappings.merge(name_mappings)

                    socket.write(COMMAND_START)
                    Marshal.dump(
                        [process_name, deployment_model.name, name_mappings, options],
                        socket
                    )
                    wait_for_answer do |pid_s|
                        if pid_s == RET_NO
                            msg = Marshal.load(socket)
                            raise Failed,
                                  "failed to start #{deployment_model.name}: #{msg}"
                        elsif pid_s == RET_STARTED_PROCESS
                            pid = Marshal.load(socket)
                            process = Process.new(
                                process_name, deployment_model, self, pid
                            )
                            process.name_mappings = name_mappings
                            processes[process_name] = process
                            return process
                        else
                            raise InternalError,
                                  "unexpected reply #{pid_s} to the start command"
                        end
                    end
                end

                # Creates a new log dir, and save the given time tag in it (used later
                # on by save_log_dir)
                def create_log_dir(log_dir, time_tag, metadata = {})
                    socket.write(COMMAND_CREATE_LOG)
                    Marshal.dump([log_dir, time_tag, metadata], socket)
                end

                def queue_death_announcement
                    @death_queue.push Marshal.load(socket)
                end

                # Initiate the upload of a file from the remote process server
                #
                # The transfer is asynchronous, use {#upload_state} to track the
                # upload progress
                def log_upload_file(host, port, certificate, user, password, localfile)
                    socket.write(COMMAND_LOG_UPLOAD_FILE)
                    Marshal.dump(
                        [host, port, certificate, user, password, localfile], socket
                    )

                    wait_for_ack
                end

                # Query the current state of log upload
                #
                # @return [UploadState]
                def log_upload_state
                    socket.write(COMMAND_LOG_UPLOAD_STATE)

                    wait_for_ack
                    Marshal.load(socket)
                end

                # Waits for processes to terminate. +timeout+ is the number of
                # milliseconds we should wait. If set to nil, the call will block until
                # a process terminates
                #
                # Returns a hash that maps deployment names to the Process::Status
                # object that represents their exit status.
                def wait_termination(timeout = nil)
                    if @death_queue.empty?
                        reader = select([socket], nil, nil, timeout)
                        return {} unless reader

                        while reader
                            if socket.eof? # remote closed, probably a crash
                                raise ComError, "communication to process server closed"
                            end

                            data = socket.read(1)
                            return {} unless data

                            if data != EVENT_DEAD_PROCESS
                                raise "unexpected message #{data} from process server"
                            end

                            queue_death_announcement
                            reader = select([socket], nil, nil, 0)
                        end
                    end

                    result = {}
                    @death_queue.each do |name, status|
                        Orocos.debug "#{name} died"
                        if (p = processes.delete(name))
                            p.dead!
                            result[p] = status
                        else
                            Orocos.warn "process server reported the exit "\
                                        "of '#{name}', but no process with "\
                                        "that name is registered"
                        end
                    end
                    @death_queue.clear

                    result
                end

                # Requests to stop the given deployment
                #
                # The call does not block until the process has quit. You will have to
                # call #wait_termination to wait for the process end.
                def stop(deployment_name, wait, cleanup: true, hard: false)
                    socket.write(COMMAND_END)
                    Marshal.dump([deployment_name, cleanup, hard], socket)
                    raise Failed, "failed to quit #{deployment_name}" unless wait_for_ack

                    join(deployment_name) if wait
                end

                def join(deployment_name)
                    process = processes[deployment_name]
                    return unless process

                    loop do
                        result = wait_termination(nil)
                        return if result[process]
                    end
                end

                def quit_server
                    socket.write(COMMAND_QUIT)
                end

                def close
                    socket.close
                end
            end
        end
    end
end
