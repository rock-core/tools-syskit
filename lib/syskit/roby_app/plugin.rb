module Syskit
    module RobyApp
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Plugin
            def syskit_engine
                if plan && plan.respond_to?(:syskit_engine)
                    plan.syskit_engine
                end
            end

            # The set of loaded orogen projects, as a mapping from the project
            # name to the corresponding TaskLibrary instance
            #
            # See #load_orogen_project.
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

            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            #
            # @return [Orocos::Generation::Project] the project object
            def load_orogen_project(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server = Syskit.conf.process_server_for(options[:on])
                server.load_orogen_project(name)
            end

            # Registers all objects contained in a given oroGen project
            #
            # @return [Orocos::Generation::Project] the project object
            def project_define_from_orogen(name, orogen)
                return loaded_orogen_projects[name] if loaded_orogen_project?(name)
                Syskit.info "loading oroGen project #{name}"

                if Orocos.available_task_libraries[name].respond_to?(:to_str)
                    orogen_path = Orocos.available_task_libraries[name]
                    if File.file?(orogen_path)
                        Orocos.master_project.register_orogen_file(Orocos.available_task_libraries[name], name)
                    end
                end
                orogen ||= Orocos.master_project.load_orogen_project(name)

                # If it is a task library, register it on our main project
                if !orogen.self_tasks.empty?
                    Orocos.master_project.using_task_library(name)
                end

		Orocos.registry.merge(orogen.registry)
                if tk = orogen.typekit
                    if Syskit.conf.only_load_models?
                        Orocos.load_typekit_registry(orogen.name)
                    else
                        Orocos.load_typekit(orogen.name)
                    end
                end
                orogen.used_typekits.each do |tk|
                    next if tk.virtual?

                    if Syskit.conf.only_load_models?
                        Orocos.load_typekit_registry(tk.name)
                    else
                        Orocos.load_typekit(tk.name)
                    end
                end
                loaded_orogen_projects[name] = orogen

                orogen.used_task_libraries.dup.each do |lib|
                    using_task_library(lib.name)
                end

                orogen.self_tasks.each do |task_def|
                    if !TaskContext.has_model_for?(task_def)
                        Syskit::TaskContext.define_from_orogen(task_def, :register => true)
                    end
                end
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install? && !Deployment.has_model_for?(deployment_def)
                        Syskit::Deployment.define_from_orogen(deployment_def, :register => true)
                    end
                end

                load_component_extension(name)

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
                        Plugin.load_task_extension(file, self)
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
                Orocos.available_task_libraries.each_key do |name|
                    using_task_library(name)
                end
            end

            # Called by the main Roby application on setup. This is the first
            # configuration step.
            def self.setup(app)
                if app.shell?
                    return
                end

                Orocos.configuration_log_name = File.join(app.log_dir, 'properties')
                Orocos.disable_sigchld_handler = true
                # Engine registers itself as plan.syskit_engine
                NetworkGeneration::Engine.new(app.plan || Roby::Plan.new)

                # Change to the log dir so that the IOR file created by the
                # CORBA bindings ends up there
                Dir.chdir(app.log_dir) do
                    if !Syskit.conf.only_load_models?
                        Orocos.initialize
                    end

                    if !app.shell? && !Syskit.conf.disables_local_process_server?
                        start_local_process_server(:redirect => Syskit.conf.redirect_local_process_server?)
                    end
                end

                Syskit::TaskContext.define_from_orogen(Orocos::Spec::TaskContext.orogen_rtt_task_context, :register => true)

                if !app.additional_model_files.empty?
                    toplevel_object.extend SingleFileDSL
                    Roby.once do
                        app.permanent_requirements.each do |req|
                            Roby.plan.add_mission(t = req.as_plan)
                        end
                    end
                end
            end

            # Called by the main Roby application to clear all before redoing a
            # setup
            def self.reload_config(app)
                Syskit.conf.clear
            end
        
            def self.load_orocosrb(app)
                ENV['ORO_LOGFILE'] = File.join(app.log_dir, "orocos.orocosrb-#{::Process.pid}.txt")
                Orocos.load
            end

            def self.require_models(app)
                if !Orocos.loaded?
                    load_orocosrb(app)
                end
                # Load user-defined dummy orogen projects
                all_files =
                    app.find_files_in_dirs("models", "orogen", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.orogen$/)
                all_files.each do |path|
                    name = File.basename(path, ".orogen")
                    if !Orocos.available_projects.has_key?(name)
                        begin
                            Orocos.beautify_loading_errors("#{name}.orogen") do
                                Orocos.load_independent_orogen_project(path)
                            end
                        rescue Exception => e
                            Roby.app.register_exception(e)
                        end
                    end
                end
                # Load configuration directories
                app.find_dirs('config', 'orogen', 'ROBOT', :order => :specific_last, :all => true).each do |dir|
                    app.isolate_load_errors("could not load oroGen configuration files in #{dir}") do
                        Orocos.conf.load_dir(dir)
                    end
                end

                Syskit.process_servers.each do |name, (client, log_dir)|
		    client.available_projects.each do |name, orogen_model|
		    	if !Orocos.available_projects.has_key?(name)
			    Orocos.master_project.register_orogen_file(orogen_model, name)
			end
		    end
		    client.available_typekits.each do |name, (registry, typelist)|
		    	if !Orocos.available_typekits.has_key?(name)
			    Orocos.master_project.register_typekit(name, registry, typelist)
			end
		    end
		end


                # Load the data services and task models
                search_path =
                    if app.syskit_load_all? then app.search_path
                    else [app.app_dir]
                    end

                all_files =
                    app.find_files_in_dirs("models", "blueprints", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("models", "profiles", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/)
                all_files.each do |path|
                    begin
                        app.require(path)
                    rescue Orocos::Generation::Project::TypeImportError => e
                        if Syskit.conf.ignore_missing_orogen_projects_during_load?
                            ::Robot.warn "ignored file #{path}: cannot load required typekit #{e.name}"
                        else raise
                        end
                    rescue Orocos::Generation::Project::MissingTaskLibrary => e
                        if Syskit.conf.ignore_missing_orogen_projects_during_load?
                            ::Robot.warn "ignored file #{path}: cannot load required task library #{e.name}"
                        else raise
                        end
                    end
                end
                if app.syskit_load_all?
                    app.syskit_load_all
                end
            end

            # Load the specified oroGen project and register the task contexts
            # and deployments they contain.
            def using_task_library(name)
                orogen = Orocos.master_project.using_task_library(name)
                if !loaded_orogen_project?(name)
                    # The project was already loaded on
                    # Orocos.master_project before Roby kicked in. Just load
                    # the Roby part
                    project_define_from_orogen(name, orogen)
                end
            end

            # Loads the required typekit
            def import_types_from(typekit_name)
                Orocos.master_project.import_types_from(typekit_name)
            end

            def self.load_task_extension(file, app)
                app.require file
            end

            # Start a process server on the local machine, and register it in
            # Syskit.process_servers under the 'localhost' name
            def self.start_local_process_server(
                    options = Orocos::ProcessServer::DEFAULT_OPTIONS,
                    port = Orocos::ProcessServer::DEFAULT_PORT)

                options, server_options = Kernel.filter_options options, :redirect => true
                if Syskit.process_servers['localhost']
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

            def self.connect_to_local_process_server
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
                Syskit.register_process_server('localhost', client, Roby.app.log_dir)
            end


            # Loads the oroGen deployment model for the given name and returns
            # the corresponding syskit model
            #
            # @option options [String] :on the name of the process server this
            #   deployment should be on. It is used for loading as well, i.e.
            #   the model for the deployment will be loaded from that process
            #   server
            def load_deployment_model(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server   = Syskit.conf.process_server_for(options[:on])
                deployer = server.load_orogen_deployment(name)

                if !loaded_orogen_project?(deployer.project.name)
                    # The project was already loaded on
                    # Orocos.master_project before Roby kicked in. Just load
                    # the Roby part
                    project_define_from_orogen(deployer.project.name, deployer.project)
                end

                deployer.used_typekits.each do |tk|
                    next if tk.virtual?
                    if Syskit.conf.only_load_models?
                        Orocos.load_typekit_registry(tk.name)
                    else
                        Orocos.load_typekit(tk.name)
                    end
                    if server.respond_to?(:preload_typekit)
                        server.preload_typekit(tk.name)
                    end
                end
                deployer.used_task_libraries.each do |lib|
                    using_task_library(lib.name)
                end

                Deployment.find_model_from_orogen_name(name)
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
                Syskit.process_servers.delete('localhost')
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
                    connect_to_local_process_server
                end

                @handler_ids = plug_engine_in_roby(Roby.engine)
            end


            def self.clear_models(app)
                Orocos.clear
                app.loaded_orogen_projects.clear
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
                Syskit.process_servers.each_value do |client, options|
                    client.disconnect
                end
                Syskit.process_servers.clear
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
            end

            class << self
                attr_accessor :toplevel_object
            end
            def self.enable
                load_orocosrb(Roby.app)
                ::Robot.include Syskit::RobyApp::RobotExtension
                ::Roby.conf.syskit = Syskit.conf
                ::Roby.extend Syskit::RobyApp::Toplevel

                Orocos.load_orogen_plugins('syskit')
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROGEN_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROCOSRB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Typelib::TYPELIB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(File.expand_path(File.join('..', ".."), File.dirname(__FILE__))))
                toplevel_object.extend LoadToplevelMethods
            end

        end
    end
end
Syskit::RobyApp::Plugin.toplevel_object = self
