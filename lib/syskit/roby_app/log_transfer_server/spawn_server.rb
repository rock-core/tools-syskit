# frozen_string_literal: true

require "ftpd"
require "ipaddr"

require "syskit/roby_app/log_transfer_server/driver"

module Syskit
    module RobyApp
        module LogTransferServer
            # Class responsible for spawning an FTP server for transfering logs
            class SpawnServer
                attr_reader :port

                # tgt_dir must be an absolute path
                def initialize(
                    tgt_dir,
                    user,
                    password,
                    certfile_path,
                    account: "",
                    interface: "127.0.0.1",
                    tls: :explicit,
                    port: 0,
                    session_timeout: default_session_timeout,
                    nat_ip: nil,
                    passive_ports: nil,
                    debug: false,
                    log: nil,
                    verbose: false)

                    @data_dir = tgt_dir
                    @interface = interface
                    @tls = tls
                    @certfile_path = certfile_path
                    @port = port
                    @auth_level = "password"
                    @user = user
                    @password = password
                    @account = account
                    @session_timeout = session_timeout
                    @nat_ip = nat_ip
                    @passive_ports = passive_ports
                    @debug = debug
                    @log = log
                    @driver = Driver.new(@user, @password, @account, @data_dir)
                    @server = Ftpd::FtpServer.new(@driver)
                    configure_server
                    @server.start
                    @port = @server.bound_port
                    display_connection_info if verbose
                end

                # The user should call this function in order to spawn the server
                def run
                    wait_until_stopped
                end

                private

                def configure_server
                    @server.interface = @interface
                    @server.port = @port
                    @server.tls = @tls
                    @server.passive_ports = @passive_ports
                    @server.certfile_path = @certfile_path
                    @server.auth_level = auth_level
                    @server.session_timeout = @session_timeout
                    @server.log = make_log
                    @server.nat_ip = @nat_ip
                end

                def auth_level
                    Ftpd.const_get("AUTH_#{@auth_level.upcase}")
                end

                def display_connection_info
                    puts "Interface: #{@server.interface}"
                    puts "Port: #{@server.bound_port}"
                    puts "User: #{@user.inspect}"
                    puts "Pass: #{@password.inspect}" if auth_level >= Ftpd::AUTH_PASSWORD
                    puts "Account: #{@account.inspect}" if auth_level >= Ftpd::AUTH_ACCOUNT
                    puts "TLS: #{@tls}"
                    puts "Directory: #{@data_dir}"
                    puts "URI: #{uri}"
                    puts "PID: #{$$}"
                end

                def uri
                    "ftp://#{connection_host}:#{@server.bound_port}"
                end

                def wait_until_stopped
                    puts "FTP server started.  Press ENTER or c-C to stop it"
                    $stdout.flush
                    begin
                        gets
                    rescue Interrupt
                        puts "Interrupt"
                    end
                end

                def make_log
                    @debug && Logger.new($stdout)
                end

                def connection_host
                    addr = IPAddr.new(@server.interface)
                    if addr.ipv6?
                        "::1"
                    else
                        "127.0.0.1"
                    end
                end

                def default_session_timeout
                    Ftpd::FtpServer::DEFAULT_SESSION_TIMEOUT
                end
            end
        end
    end
end
