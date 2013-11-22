module Syskit
    module RobyApp
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Plugin
            def orogen_loader
                Orocos.default_loader
            end

            def syskit_engine
                if plan && plan.respond_to?(:syskit_engine)
                    plan.syskit_engine
                end
            end

            # @return [Hash<String,OroGen::Spec::Project>] the set of projects
            #   loaded so far
            attribute(:loaded_orogen_projects) { Hash.new }

            # Set of requirements that should be added to the running system.
            # This is meant to be used only by "syskit scripts" through
            # SingleFileDSL
            #
            # @return [Array<InstanceRequirements>]
            attribute(:permanent_requirements) { Array.new }

            def self.load(app, options)
                conf = Syskit.conf
                if options = options['syskit']
                    conf.prefix = options['prefix']
                    conf.exclude_from_prefixing.concat(options['exclude_from_prefixing'] || [])
                    conf.sd_domain = options['sd_domain']
                    conf.publish_on_sd.concat(options['publish_on_sd'] || [])
                end
            end

            def self.finalize_model_loading(app)
                if toplevel_object.respond_to?(:global_profile)
                    ::Main.use_profile toplevel_object.global_profile
                end
            end

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.has_key?(name) end

            # Registers all objects contained in a given oroGen project
            #
            # @param [OroGen::Spec::Project] orogen the oroGen project that
            #   should be added to the Syskit side
            def project_define_from_orogen(orogen)
                return if loaded_orogen_projects.has_key?(orogen.name)
                Syskit.info "loading oroGen project #{orogen.name}"

                orogen.self_tasks.each_value do |task_def|
                    # Load configuration directories
                    if conf_file = find_file('config', 'orogen', 'ROBOT', "#{task_def.name}.yml", :order => :specific_first, :all => true)
                        isolate_load_errors("could not load oroGen configuration file #{conf_file}") do
                            Orocos.conf.load_file(conf_file, task_def)
                        end
                    end
                    if !TaskContext.has_model_for?(task_def)
                        Syskit::TaskContext.define_from_orogen(task_def, :register => true)
                    end
                end

                load_component_extension(orogen.name)

                orogen
            end

            def load_component_extension(name)
                # If we are loading under Roby, get the plugins for the orogen
                # project
                if Syskit.conf.load_component_extensions?
                    file = find_file('models', 'orogen', "#{name}.rb", :order => :specific_first) ||
                        find_file('tasks', 'orogen', "#{name}.rb", :order => :specific_first) ||
                        find_file('tasks', 'components', "#{name}.rb", :order => :specific_first)

                    if file
                        Roby::Application.info "loading task extension #{file}"
                        require file
                    end
                end
            end

            # If true, syskit is loading all available oroGen projects on this
            # system. It is set automatically by #syskit_load_all to ensure that
            # everything is reloaded when the app reloads its models
            attr_predicate :syskit_load_all?, true

            # Loads all available oroGen projects
            def syskit_load_all
                self.syskit_load_all = true
                Orocos.default_pkgconfig_loader.available_task_libraries.each_key do |name|
                    using_task_library(name)
                end
            end

            # Called by the main Roby application on setup. This is the first
            # configuration step.
            def self.setup(app)
                if Syskit.conf.use_only_model_pack?
                    Orocos.default_loader.remove Orocos.default_pkgconfig_loader
                end

                all_files =
                    app.find_files_in_dirs("models", "ROBOT", "pack", "orogen", :all => true, :order => :specific_last, :pattern => /\.orogen$/)
                all_files.each do |path|
                    name = File.basename(path, ".orogen")
                    Orocos.default_file_loader.register_orogen_file path, name
                end

                all_files =
                    app.find_files_in_dirs("models", "ROBOT", "pack", "orogen", :all => true, :order => :specific_last, :pattern => /\.typelist$/)
                all_files.each do |path|
                    name = File.basename(path, ".typelist")
                    dir  = File.dirname(path)
                    Orocos.default_file_loader.register_typekit dir, name
                end

                Orocos::ROS.default_loader.
                    search_path.concat(Roby.app.find_dirs('models', 'ROBOT', 'orogen', 'ros', :all => true, :order => :specific_first))
                Orocos::ROS.default_loader.
                    packs.concat(Roby.app.find_dirs('models', 'ROBOT', 'pack', 'ros', :all => true, :order => :specific_last))

                if app.shell?
                    return
                end

                Orocos.configuration_log_name = File.join(app.log_dir, 'properties')
                Orocos.disable_sigchld_handler = true
                # Engine registers itself as plan.syskit_engine
                NetworkGeneration::Engine.new(app.plan || Roby::Plan.new)

                Syskit.conf.register_process_server('ros', Orocos::ROS::ProcessManager.new, app.log_dir)

                ENV['ORO_LOGFILE'] = File.join(app.log_dir, "orocos.orocosrb-#{::Process.pid}.txt")
                if Syskit.conf.only_load_models?
                    fake_client = Configuration::ModelOnlyServer.new(Orocos.default_loader)
                    Syskit.conf.register_process_server('localhost', fake_client, app.log_dir)
                    Orocos.load
                    if Orocos::ROS.available?
                        Orocos::ROS.load
                    end

                else
                    # Change to the log dir so that the IOR file created by
                    # the CORBA bindings ends up there
                    Dir.chdir(app.log_dir) do
                        Orocos.initialize
                        if Orocos::ROS.enabled?
                            Orocos::ROS.initialize
                            Orocos::ROS.roscore_start(:wait => true)
                        end

                        if !Syskit.conf.disables_local_process_server?
                            start_local_process_server(:redirect => Syskit.conf.redirect_local_process_server?)
                        end
                    end
                end

                Syskit::TaskContext.define_from_orogen(app.orogen_loader.task_model_from_name("RTT::TaskContext"), :register => true)

                if !app.additional_model_files.empty?
                    toplevel_object.extend SingleFileDSL
                    Roby.once do
                        app.permanent_requirements.each do |req|
                            Roby.plan.add_mission(req.as_plan)
                        end
                    end
                end
            end

            # Called by the main Roby application to clear all before redoing a
            # setup
            def self.reload_config(app)
                Syskit.conf.clear
            end

            def self.require_models(app)
                # Load the data services and task models
                search_path =
                    if app.syskit_load_all? then app.search_path
                    else [app.app_dir]
                    end

                if !app.testing?
                    all_files =
                        app.find_files_in_dirs("models", "blueprints", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                        app.find_files_in_dirs("models", "profiles", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/)
                   all_files.each do |path|
                        begin
                            app.require(path)
                        rescue OroGen::NotFound => e
                            if Syskit.conf.ignore_missing_orogen_projects_during_load?
                                ::Robot.warn "ignored file #{path}: #{e.message}"
                            else raise
                            end
                        end
                    end
                    if app.syskit_load_all?
                        app.syskit_load_all
                    end
                end
            end

            # Loads the required typekit model by its name
            def import_types_from(typekit_name)
                orogen_loader.typekit_model_from_name(typekit_name)
            end

            # Load the specified oroGen project and register the task contexts
            # and deployments they contain.
            def using_task_library(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server = Syskit.conf.process_server_for(options[:on])
                # The loader hooks will make sure that the models get defined
                server.loader.project_model_from_name(name)
            end

            # Loads the required ROS package
            def using_ros_package(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'ros'
                using_task_library(name, options)
            end

            # @deprecated use {using_task_library} instead
            def load_orogen_project(name, options = Hash.new)
                using_task_library(name, options)
            end

            # Start a process server on the local machine, and register it in
            # Syskit.process_servers under the 'localhost' name
            def self.start_local_process_server(
                    options = Orocos::ProcessServer::DEFAULT_OPTIONS,
                    port = Orocos::ProcessServer::DEFAULT_PORT)

                options, server_options = Kernel.filter_options options, :redirect => true
                if Syskit.conf.process_servers['localhost']
                    raise ArgumentError, "there is already a process server called 'localhost' running"
                end

                if !File.exists?(Roby.app.log_dir)
                    FileUtils.mkdir_p(Roby.app.log_dir)
                end
                @server_pid = Utilrb.spawn 'orocos_process_server', "--port=#{port}", "--debug",
                    :redirect => (if options[:redirect] then 'local_process_server.txt' end),
                    :working_directory => Roby.app.log_dir

                @server_port = port
                nil
            end

            def self.has_local_process_server?
                @server_pid
            end

            def self.connect_to_local_process_server(app)
                if !@server_pid
                    raise Orocos::ProcessClient::StartupFailed, "#connect_to_local_process_server got called but no process server is being started"
                end

                # Wait for the server to be ready
                client = nil
                while !client
                    client =
                        begin Orocos::ProcessClient.new('localhost', @server_port)
                        rescue Errno::ECONNREFUSED
                            sleep 0.1
                            is_running = 
                                begin
                                    !::Process.waitpid(@server_pid, ::Process::WNOHANG)
                                rescue Errno::ESRCH
                                    false
                                end

                            if !is_running
                                raise Orocos::ProcessClient::StartupFailed, "the local process server failed to start"
                            end
                            nil
                        end
                end

                # Verify that the server is actually ours (i.e. check that there
                # was not one that was still running)
                if client.server_pid != @server_pid
                    raise Orocos::ProcessClient::StartupFailed, "failed to start the local process server. It seems that there is one still running as PID #{client.server_pid}"
                end

                # Do *not* manage the log directory for that one ...
                Syskit.conf.register_process_server('localhost', client, app.log_dir)
            end

            # Loads the oroGen deployment model for the given name and returns
            # the corresponding syskit model
            #
            # @option options [String] :on the name of the process server this
            #   deployment should be on. It is used for loading as well, i.e.
            #   the model for the deployment will be loaded from that process
            #   server
            def using_deployment(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server   = Syskit.conf.process_server_for(options[:on])
                deployer = server.loader.deployment_model_from_name(name)
                deployment_define_from_orogen(deployer)
            end

            # Loads the oroGen deployment model based on a ROS launcher file
            def using_ros_launcher(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'ros'
                using_deployment(name, options)
            end

            # Loads the oroGen deployment model for the given name and returns
            # the corresponding syskit model
            #
            # @option options [String] :on the name of the process server this
            #   deployment should be on. It is used for loading as well, i.e.
            #   the model for the deployment will be loaded from that process
            #   server
            def deployment_define_from_orogen(deployer)
                if Deployment.has_model_for?(deployer)
                    Deployment.find_model_by_orogen(deployer)
                else
                    Deployment.define_from_orogen(deployer, :register => true)
                end
            end

            # Stop the process server started by start_local_process_server if
            # one is running
            def self.stop_local_process_server
                return if !has_local_process_server?

                ::Process.kill('INT', @server_pid)
                begin
                    ::Process.waitpid(@server_pid)
                    @server_pid = nil
                rescue Errno::ESRCH
                end
                Syskit.conf.remove_process_server 'localhost'
            end

            ##
            # :attr: local_only?
            #
            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            def self.roby_engine_propagation_handlers
                handlers = Hash.new
                handlers[:update_deployment_states] = [Runtime.method(:update_deployment_states), :type => :external_events]
                handlers[:update_task_states] = [Runtime.method(:update_task_states), :type => :external_events]
                handlers[:update] = [Runtime::ConnectionManagement.method(:update), :type => :propagation, :late => true]
                handlers[:apply_requirement_modifications] = [Runtime.method(:apply_requirement_modifications), :type => :propagation, :late => true]
                handlers
            end

            def self.plug_engine_in_roby(roby_engine)
                handler_ids = Hash.new
                roby_engine_propagation_handlers.each do |name, (m, options)|
                    handler_ids[name] = roby_engine.add_propagation_handler(options, &m)
                end
                handler_ids
            end

            def self.unplug_engine_from_roby(handler_ids, roby_engine)
                handler_ids.each do |handler_id|
                    roby_engine.remove_propagation_handler(handler_id)
                end
            end

            def self.disable_engine_in_roby(roby_engine, *handlers)
                if @handler_ids
                    handlers.each do |h|
                        roby_engine.remove_propagation_handler(@handler_ids.delete(h))
                    end

                    begin
                        yield
                    ensure
                        all_handlers = roby_engine_propagation_handlers
                        handlers.each do |h|
                            @handler_ids[h] = roby_engine.add_propagation_handler(all_handlers[h][1], &all_handlers[h][0])
                        end
                    end
                else yield
                end
            end

            def self.prepare(app)
                if has_local_process_server?
                    connect_to_local_process_server(app)
                end

                @handler_ids = plug_engine_in_roby(Roby.engine)
            end


            def self.clear_models(app)
                Orocos.clear
                Syskit.conf.deployments.clear
                Syskit::Actions::Profile.clear_model

                # This needs to be cleared here and not in
                # Component.clear_model. The main reason is that we need to
                # clear them on every component model class. Some of them are
                # therefore not reloaded by the regular Roby model-clearing
                # mechanism
                Syskit::Component.proxy_task_models.clear
                Syskit::Component.each_submodel do |sub|
                    sub.proxy_task_models.clear
                end
            end

            def self.cleanup(app)
                remaining = Orocos.each_process.to_a
                if !remaining.empty?
                    Syskit.warn "killing remaining Orocos processes: #{remaining.map(&:name).join(", ")}"
                    Orocos::Process.kill(remaining)
                end

                if @handler_ids
                    unplug_engine_from_roby(@handler_ids.values, Roby.engine)
                    @handler_ids = nil
                end

                Syskit.conf.deployments.clear
                stop_process_servers
                stop_local_process_server
            end

            def self.stop_process_servers
                # Stop the local process server if we started it ourselves
                Syskit.conf.each_process_server do |client, options|
                    client.disconnect
                end
                Syskit.conf.process_servers.clear
            end

            module LoadToplevelMethods
                # Imports the types from the given typekit(s)
                def import_types_from(name)
                    Roby.app.import_types_from(name)
                end

                # Loads the given task library
                def using_task_library(name)
                    Roby.app.using_task_library(name)
                end

                # Loads a ROS package description
                def using_ros_package(name)
                    Roby.app.using_ros_package(name)
                end
            end

            class << self
                attr_accessor :toplevel_object
            end
            def self.enable
                ::Robot.include Syskit::RobyApp::RobotExtension
                ::Roby.conf.syskit = Syskit.conf
                ::Roby.extend Syskit::RobyApp::Toplevel

                OroGen.load_orogen_plugins('syskit')
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(OroGen::OROGEN_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROCOSRB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Typelib::TYPELIB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(File.expand_path(File.join('..', ".."), File.dirname(__FILE__))))
                toplevel_object.extend LoadToplevelMethods
            end

        end
    end
end
Syskit::RobyApp::Plugin.toplevel_object = self
