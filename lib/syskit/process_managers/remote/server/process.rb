# frozen_string_literal: true

module Syskit
    module ProcessManagers
        module Remote
            module Server
                # The representation of an Orocos process. It manages
                # starting the process and cleaning up when the process
                # dies.
                class Process
                    extend Logger::Forward
                    extend Logger::Hierarchy
                    include Logger::Forward
                    include Logger::Hierarchy

                    # The component process ID
                    #
                    # @return [Integer,nil]
                    attr_reader :name

                    # The component process ID
                    #
                    # @return [Integer,nil]
                    attr_reader :pid

                    # Creates a new Process instance which will be able to
                    # start and supervise the execution of the given Orocos
                    # component
                    #
                    # @param [String] name the process name
                    # @param [OroGen::Spec::Deployment] model the process deployment'
                    #
                    # @overload initialize(name, model_name = name)
                    #   deprecated form
                    #   @param [String] name the process name
                    #   @param [String] model_name the name of the deployment model
                    #
                    def initialize(name, deployment_name, loader, working_directory)
                        binfile =
                            if loader.respond_to?(:find_deployment_binfile)
                                loader.find_deployment_binfile(deployment_name)
                            else
                                loader.available_deployments
                                      .fetch(deployment_name).binfile
                            end

                        @name = name
                        @name_mappings = {}

                        @env = {}
                        @command = binfile
                        @arguments = []
                        @working_directory = working_directory

                        @redirect_output = "%m-%p.txt"
                        @redirect_orocos_logger_output = "orocos.%m-%p.txt"

                        @execution_mode = {}
                    end

                    def self.tracing_library_path
                        tracing_pkg =
                            Utilrb::PkgConfig.new("orocos-rtt-#{Orocos.orocos_target}")

                        File.join(
                            tracing_pkg.libdir,
                            "liborocos-rtt-traces-#{Orocos.orocos_target}.so"
                        )
                    end

                    def enable_tracing
                        @env["LD_PRELOAD"] = self.class.tracing_library_path
                    end

                    def add_name_mappings(mappings)
                        @arguments += mappings.map do |old, new|
                            "--rename=#{old}:#{new}"
                        end
                    end

                    def setup_log_level(log_level)
                        unless VALID_LOG_LEVELS.include?(log_level)
                            raise ArgumentError,
                                  "'#{log_level}' is not a valid log level." \
                                  " Valid options are #{valid_levels}."
                        end

                        @env["BASE_LOG_LEVEL"] = log_level.to_s.upcase
                    end

                    def setup_corba(name_service_ip)
                        if name_service_ip
                            @env["ORBInitRef"] =
                                "NameService=corbaname::#{name_service_ip}"
                        else
                            @arguments << "--register-on-name-server" << "0"
                        end
                    end

                    # Command line arguments have to be of type --<option>=<value>
                    # or if <value> is nil a valueless option, i.e. --<option>
                    def push_args_from_hash(cmdline_args)
                        @arguments += cmdline_args.flat_map do |option, value|
                            if value
                                if value.respond_to?(:to_ary)
                                    value.map { |v| "--#{option}=#{v}" }
                                else
                                    "--#{option}=#{value}"
                                end
                            else
                                "--#{option}"
                            end
                        end
                    end

                    def push_arg(string)
                        @arguments << string
                        self
                    end

                    def setup_rr
                        @arguments.unshift(@command)
                        @arguments.unshift(
                            proc do
                                trace_dir_basename =
                                    resolve_file_pattern("rr-%m-%p", ::Process.pid)
                                "--output-trace-dir=#{trace_dir_basename}"
                            end
                        )
                        @arguments.unshift("record")
                        @command = "rr"
                        @execution_mode = { type: "rr" }
                        self
                    end

                    def setup_gdbserver(port: Process.allocate_gdb_port)
                        @arguments.unshift(@command)
                        @arguments.unshift(":#{port}")
                        @command = "gdbserver"
                        @execution_mode = { type: "gdbserver", port: port }
                        self
                    end

                    def setup_valgrind(output: "%m-%p.valgrind.txt")
                        @arguments.unshift(@command)
                        @arguments.unshift(
                            proc do
                                log_file_basename =
                                    resolve_file_pattern(output, ::Process.pid)
                                "--log-file=#{log_file_basename}"
                            end
                        )
                        @command = "valgrind"
                        @execution_mode = { type: "valgrind", output: output }
                        self
                    end

                    def resolve_file_pattern(path, pid)
                        resolved =
                            path
                            .gsub("%m", @name)
                            .gsub("%p", pid.to_s)

                        File.expand_path(resolved, @working_directory)
                    end

                    def redirect_output(pattern)
                        @redirect_output = pattern
                        self
                    end

                    def redirect_orocos_logger_output(pattern)
                        @redirect_orocos_logger_output = pattern
                        self
                    end

                    def apply_env(env)
                        @env.each do |k, v|
                            env[k] = v
                        end
                    end

                    def setup_execution_mode(type: nil, **options)
                        send("setup_#{type}", **options) if type
                    end

                    # Waits until the process dies
                    #
                    # This is valid only if the module has been started
                    # under Orocos supervision, using {#spawn}
                    def join
                        return unless alive?

                        begin
                            _, exit_status = ::Process.waitpid2(pid)
                            dead!(exit_status)
                        rescue Errno::ECHILD # rubocop:disable Lint/SuppressedException
                        end
                    end

                    # Called externally to announce a component dead.
                    def dead!(exit_status) # :nodoc:
                        exit_status = (@exit_status ||= exit_status)

                        if !exit_status
                            info "deployment #{name} exited, exit status unknown"
                        elsif exit_status.success?
                            info "deployment #{name} exited normally"
                        elsif exit_status.signaled?
                            issue_logger_signaled_messages(exit_status)
                        else
                            warn "deployment #{name} terminated with code "\
                                 "#{exit_status.to_i}"
                        end

                        pid = @pid
                        @pid = nil
                        pid
                    end

                    def issue_logger_signaled_messages(exit_status)
                        if @expected_exit == exit_status.termsig
                            info "deployment #{name} terminated with signal "\
                                 "#{exit_status.termsig}"
                        elsif @expected_exit
                            info "deployment #{name} terminated with signal "\
                                 "#{exit_status.termsig} but #{@expected_exit} "\
                                 "was expected"
                        else
                            error "deployment #{name} unexpectedly terminated with "\
                                  "signal #{exit_status.termsig}"
                            error "This is normally a fault inside the component, "\
                                  "not caused by the framework."
                        end
                    end

                    # True if the process is running
                    def running?
                        alive?
                    end

                    # @api private
                    #
                    # Checks that the given command can be resolved
                    def self.has_command?(cmd)
                        return if File.file?(cmd) && File.executable?(cmd)

                        system("which #{cmd} > /dev/null 2>&1")
                    end

                    @gdb_port = 30_000

                    def self.gdb_base_port=(port)
                        @gdb_port = port - 1
                    end

                    def self.allocate_gdb_port
                        @gdb_port += 1
                    end

                    VALID_LOG_LEVELS = %I[debug info warn error fatal disable].freeze

                    # Spawns this process
                    def spawn
                        @ior_message = +""

                        @ior_read_fd, ior_write_fd = IO.pipe
                        read, write = IO.pipe
                        @pid = fork do
                            read.close
                            spawn_setup_forked_process_and_exec(write, ior_write_fd)
                        end
                        ior_write_fd.close
                        write.close
                        raise "cannot start #{@name}" if read.read == "FAILED"

                        spawn_gdb_warning if @execution_mode[:type] == "gdb"
                    end

                    def spawn_gdb_warning
                        gdb_port = @execution_mode[:port]
                        Orocos.warn(
                            "process #{name} has been started under gdbserver, "\
                            "port=#{gdb_port}. The components will not be "\
                            "functional until you attach a GDB to the started server"
                        )
                    end

                    def resolve_arguments
                        @arguments.map do |arg|
                            arg = arg.call if arg.respond_to?(:call)
                            arg.to_str
                        end
                    end

                    # Resolve the path to which the orocos logger should be redirected and
                    # return it
                    #
                    # @return [String]
                    def resolve_orocos_logger_output(pid)
                        return "/dev/null" if @redirect_orocos_logger_output

                        resolve_file_pattern(
                            @redirect_orocos_logger_output, pid
                        )
                    end

                    # Resolve the path to which the output should be redirected and
                    # return the keyword arguments that should be passed to exec
                    #
                    # @return [Hash]
                    def resolve_redirect_output(pid)
                        return {} unless @redirect_output

                        output_file_name = resolve_file_pattern(@redirect_output, pid)
                        file = File.open(output_file_name, "a")
                        { out: file, err: file }
                    end

                    # Do the necessary work within the fork and exec the deployment
                    def spawn_setup_forked_process_and_exec(write_pipe, ior_write_fd)
                        @ior_read_fd.close

                        arguments = resolve_arguments
                        arguments << "--ior-write-fd=#{ior_write_fd.fileno}"

                        apply_env(ENV)

                        pid = ::Process.pid
                        output_redirect = resolve_redirect_output(pid)
                        ENV["ORO_LOGFILE"] = resolve_orocos_logger_output(pid)

                        ::Process.setpgrp
                        begin
                            exec(@command, *arguments,
                                 ior_write_fd => ior_write_fd, **output_redirect,
                                 chdir: @working_directory)
                        rescue Exception => e # rubocop:disable Lint/RescueException
                            pp e
                            write_pipe.write("FAILED")
                        end
                    end

                    # Read the IOR pipe and parse the received message, closing the read
                    # file descriptor when end of file is reached.
                    #
                    # @return [nil, Hash<String, String>] when a complete, valid IOR
                    #   message has been received, return it as a { task name => ior }
                    #   hash. Otherwise, returns nil
                    def wait_running
                        loop do
                            @ior_message += @ior_read_fd.read_nonblock(4096)
                        end
                    rescue IO::WaitReadable
                        nil
                    rescue EOFError
                        @ior_read_fd.close
                        load_ior_message(@ior_message)
                    end

                    # Load and validate the ior message read from the IOR pipe.
                    #
                    # @param [String] message the ior message read from the pipe
                    # @return [Hash<String, String>, nil] the parsed ior message as a
                    #   { task name => ior} hash, or nil if the message could not be
                    #   parsed.
                    # @raise Orocos::InvalidIORMessage raised if the message received is
                    #   not valid
                    def load_ior_message(message)
                        JSON.parse(message)
                    rescue JSON::ParserError
                        raise Orocos::InvalidIORMessage,
                              "received IOR message is not valid JSON"
                    end

                    SIGNAL_NUMBERS = {
                        "SIGABRT" => 1,
                        "SIGINT" => 2,
                        "SIGKILL" => 9,
                        "SIGSEGV" => 11
                    }.freeze

                    # Kills the process
                    #
                    # @param [Boolean] hard if we should request a shutdown (false) or
                    #   forcefully kill the process with SIGKILL
                    def kill(hard: false)
                        tpid = pid
                        return unless tpid # already dead

                        signal =
                            if hard
                                "SIGKILL"
                            else
                                "SIGINT"
                            end

                        expected_exit = nil
                        Orocos.warn "sending #{signal} to #{name}" unless expected_exit

                        @expected_exit = SIGNAL_NUMBERS[signal] || signal
                        begin
                            ::Process.kill(signal, tpid)
                        rescue Errno::ESRCH # rubocop:disable Lint/SuppressedException
                        end
                    end
                end
            end
        end
    end
end
