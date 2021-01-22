require 'orocos/remote_processes/loader'

module Orocos
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
            "#<Orocos::RemoteProcesses::Client #{host}:#{port}>"
        end
        def inspect; to_s end

        # Connects to the process server at +host+:+port+
        #
        # @option options [Orocos::NameService] :name_service
        #   (Orocos.name_service). The name service object that should be used
        #   to resolve tasks started by this process server
        # @option options [OroGen::Loaders::Base] :root_loader
        #   (Orocos.default_loader). The loader object that should be used as
        #   root for this client's loader
        def initialize(host = 'localhost', port = DEFAULT_PORT, response_timeout: 10, root_loader: Orocos.default_loader, name_service: Orocos.name_service)
            @host = host
            @port = port
            @socket =
                begin TCPSocket.new(host, port)
                rescue Errno::ECONNREFUSED => e
                    raise e.class, "cannot contact process server at '#{host}:#{port}': #{e.message}"
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
            @processes = Hash.new
            @death_queue = Array.new
            @host_id = "#{host}:#{port}:#{server_pid}"
            @response_timeout = response_timeout
        end

        def pid(timeout: @response_timeout)
            if @server_pid
                return @server_pid
            end

            socket.write(COMMAND_GET_PID)
	    if !select([socket], [], [], timeout)
	       raise "timeout while reading process server at '#{host}:#{port}'"
	    end
            @server_pid = Integer(Marshal.load(socket).first)
        end

        def info(timeout: @response_timeout)
            socket.write(COMMAND_GET_INFO)
	    if !select([socket], [], [], timeout)
	       raise "timeout while reading process server at '#{host}:#{port}'"
	    end
            Marshal.load(socket)
        end

        def disconnect
            socket.close
        end

        class TimeoutError < RuntimeError
        end

        def wait_for_answer(timeout: @response_timeout)
            while true
                if !select([socket], [], [], timeout)
                    raise TimeoutError, "reached timeout of #{timeout}s in #wait_for_answer"
                end

                reply = socket.read(1)
                if !reply
                    raise Orocos::ComError, "failed to read from process server #{self}"
                elsif reply == EVENT_DEAD_PROCESS
                    queue_death_announcement
                else
                    yield(reply)
                end
            end
        end

        def wait_for_ack
            wait_for_answer do |reply|
                if reply == RET_YES
                    return true
                elsif reply == RET_NO
                    return false
                else
                    raise InternalError, "unexpected reply #{reply}"
                end
            end
        end

        # Starts the given deployment on the remote server, without waiting for
        # it to be ready.
        #
        # Returns a RemoteProcess instance that represents the process on the
        # remote side.
        #
        # Raises Failed if the server reports a startup failure
        def start(process_name, deployment, name_mappings = Hash.new, options = Hash.new)
            if processes[process_name]
                raise ArgumentError, "this client already started a process called #{process_name}"
            end

            if deployment.respond_to?(:to_str)
                deployment_model = loader.root_loader.deployment_model_from_name(deployment)
                if !loader.has_deployment?(deployment)
                    raise OroGen::DeploymentModelNotFound, "deployment #{deployment} exists locally but not on the remote process server #{self}"
                end
            else deployment_model = deployment
            end

            prefix_mappings = Orocos::ProcessBase.resolve_prefix(deployment_model, options.delete(:prefix))
            name_mappings = prefix_mappings.merge(name_mappings)

            socket.write(COMMAND_START)
            Marshal.dump([process_name, deployment_model.name, name_mappings, options], socket)
            wait_for_answer do |pid_s|
                if pid_s == RET_NO
                    msg = Marshal.load(socket)
                    raise Failed, "failed to start #{deployment_model.name}: #{msg}"
                elsif pid_s == RET_STARTED_PROCESS
                    pid = Marshal.load(socket)
                    process = Process.new(process_name, deployment_model, self, pid)
                    process.name_mappings = name_mappings
                    processes[process_name] = process
                    return process
                else
                    raise InternalError, "unexpected reply #{pid_s} to the start command"
                end
            end
        end

        # Requests that the process server moves the log directory at +log_dir+
        # to +results_dir+
        def save_log_dir(log_dir, results_dir)
            socket.write(COMMAND_MOVE_LOG)
            Marshal.dump([log_dir, results_dir], socket)
        end

        # Creates a new log dir, and save the given time tag in it (used later
        # on by save_log_dir)
        def create_log_dir(log_dir, time_tag, metadata = Hash.new)
            socket.write(COMMAND_CREATE_LOG)
            Marshal.dump([log_dir, time_tag, metadata], socket)
        end

        def queue_death_announcement
            @death_queue.push Marshal.load(socket)
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
                return Hash.new if !reader
                while reader
                    if socket.eof? # remote closed, probably a crash
                        raise ComError, "communication to process server closed"
                    end

                    data = socket.read(1)
                    if !data
                        return Hash.new
                    elsif data != EVENT_DEAD_PROCESS
                        raise "unexpected message #{data} from process server"
                    end
                    queue_death_announcement
                    reader = select([socket], nil, nil, 0)
                end
            end

            result = Hash.new
            @death_queue.each do |name, status|
                Orocos.debug "#{name} died"
                if p = processes.delete(name)
                    p.dead!
                    result[p] = status
                else
                    Orocos.warn "process server reported the exit of '#{name}', but no process with that name is registered"
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
            if !wait_for_ack
                raise Failed, "failed to quit #{deployment_name}"
            end

            if wait
                join(deployment_name)
            end
        end

        def join(deployment_name)
            process = processes[deployment_name]
            return if !process

            while true
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

