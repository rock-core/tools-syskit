require 'syskit/test/self'
require 'orocos/remote_processes/server'

module Syskit
    module RobyApp
        describe Plugin do
            describe "remote model loading" do
                def create_process_server(name)
                    set_log_level Orocos::RemoteProcesses::Server, Logger::FATAL

                    loader = OroGen::Loaders::Files.new
                    OroGen::Loaders::RTT.setup_loader(loader)
                    loader.register_orogen_file(File.join(data_dir, "plugin_remote_model_loading.orogen"))
                    server = Orocos::RemoteProcesses::Server.new(
                        Orocos::RemoteProcesses::Server::DEFAULT_OPTIONS,
                        0,
                        loader)
                    server.open

                    thread = Thread.new do
                        server.listen
                    end
                    client  = Syskit.conf.connect_to_orocos_process_server(
                        name, 'localhost', port: server.port)
                    @process_servers << [name, thread, client]
                end

                attr_reader :server0, :server1
                before do
                    Syskit.conf.only_load_models = false
                    @process_servers = Array.new
                    @server0 = create_process_server("server0")
                    @server1 = create_process_server("server1")
                end

                after do
                    @process_servers.each do |name, thread, client|
                        client.close
                        Syskit.conf.remove_process_server(name)
                        thread.raise Interrupt
                    end
                end

                it "registers a given deployment model only once" do
                    Roby.app.using_task_library 'plugin_remote_model_loading'

                    m0 = Syskit.conf.use_deployment 'plugin_remote_model_loading' => 'm0', on: 'server0'
                    m0 = m0.first
                    m1 = Syskit.conf.use_deployment 'plugin_remote_model_loading' => 'm1', on: 'server1'
                    m1 = m1.first

                    assert_same m0.model.orogen_model, m1.model.orogen_model
                    assert_same OroGen::PluginRemoteModelLoading::Task.orogen_model,
                        m1.orogen_model.find_task_by_name('m1task').task_model
                end
            end
            describe "local process server startup" do
                before do
                    Syskit.conf.remove_process_server 'localhost'
                end

                it "starts the process server on an ephemeral port and can connect to it" do
                    Plugin.start_local_process_server
                    client = Plugin.connect_to_local_process_server(Roby.app)
                    assert_same client, Syskit.conf.process_server_for('localhost')

                end
            end
        end

    end
end

