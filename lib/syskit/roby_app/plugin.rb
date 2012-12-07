module Syskit
    module RobyApp
        # Overloaded methods in Orocos.master_project, to load oroGen projects
        # when 
        module MasterProjectHook
            def register_loaded_project(name, project)
                super
                Roby.app.project_define_from_orogen(name, project)
            end
        end

        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Plugin
            # The set of loaded orogen projects, as a mapping from the project
            # name to the corresponding TaskLibrary instance
            #
            # See #load_orogen_project.
            attribute(:loaded_orogen_projects) { Hash.new }

            # If true, we will load the component-specific code in
            # tasks/orocos/. It is true by default
            attr_predicate :orocos_load_component_extensions, true

            # If true, the output of the local process server is redirected
            # towards <log_dir>/local_process_server.txt.
            #
            # It is true by default
            attr_predicate :redirect_local_process_server?, :true

            def self.load(app, options)
                app.orocos_load_component_extensions = true
            end

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.has_key?(name) end

            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            #
            # @returns [Orocos::Generation::Project] the project object
            def load_orogen_project(name, options = Hash.new)
                options = Kernel.validate_options :on => 'localhost'
                server = Roby::Conf.process_server_for(options[:on])
                server.load_orogen_project(project_name)
            end

            # Registers all objects contained in a given oroGen project
            #
            # @returns [Orocos::Generation::Project] the project object
            def project_define_from_orogen(name, orogen)
                Syskit.info "loading oroGen project #{name}"
                return loaded_orogen_projects[name] if loaded_orogen_project?(name)

                if Orocos.available_task_libraries[name].respond_to?(:to_str)
                    orogen_path = Orocos.available_task_libraries[name]
                    if File.file?(orogen_path)
                        Orocos.main_project.register_orogen_file(Orocos.available_task_libraries[name], name)
                    end
                end
                orogen ||= Orocos.main_project.load_orogen_project(name)

                # If it is a task library, register it on our main project
                if !orogen.self_tasks.empty?
                    Orocos.main_project.using_task_library(name)
                end

		Orocos.registry.merge(orogen.registry)
                if tk = orogen.typekit
                    if orocos_only_load_models?
                        Orocos.load_typekit_registry(orogen.name)
                    else
                        Orocos.load_typekit(orogen.name)
                    end
                end
                orogen.used_typekits.each do |tk|
                    next if tk.virtual?

                    if orocos_only_load_models?
                        Orocos.load_typekit_registry(tk.name)
                    else
                        Orocos.load_typekit(tk.name)
                    end
                end
                loaded_orogen_projects[name] = orogen

                orogen.used_task_libraries.each do |lib|
                    load_orogen_project(lib.name)
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

                # If we are loading under Roby, get the plugins for the orogen
                # project
                if orocos_load_component_extensions?
                    file = find_file('models', 'orogen', "#{name}.rb", :order => :specific_first) ||
                        find_file('tasks', 'orogen', "#{name}.rb", :order => :specific_first) ||
                        find_file('tasks', 'components', "#{name}.rb", :order => :specific_first)

                    if file
                        Roby::Application.info "loading task extension #{file}"
                        Application.load_task_extension(file, self)
                    end
                end
                orogen
            end

            # Loads all available oroGen projects
            def orocos_load_all
                Orocos.available_projects.each_key do |name|
                    Orocos.master_project.load_orogen_project(name)
                end
            end

            # Called by the main Roby application on setup. This is the first
            # configuration step.
            def self.setup(app)
                if app.shell?
                    return
                end

                Orocos.configuration_log_name ||= File.join(app.log_dir, 'properties')
                Orocos.disable_sigchld_handler = true
                app.plan.orocos_engine = NetworkGeneration::Engine.new(app.plan || Roby::Plan.new)

                # Change to the log dir so that the IOR file created by the
                # CORBA bindings ends up there
                Dir.chdir(app.log_dir) do
                    if !Syskit.conf.only_load_models?
                        Orocos.initialize
                    end

                    if !app.shell? && !Syskit.conf.disables_local_process_server?
                        start_local_process_server(:redirect => app.redirect_local_process_server?)
                    end
                end

                Syskit::TaskContext.define_from_orogen(Orocos::Spec::TaskContext.orogen_rtt_task_context, :register => true)
            end

            # Called by the main Roby application to clear all before redoing a
            # setup
            def self.reload_config(app)
                Syskit.conf.clear
            end

            def self.require_models(app)
                if !Orocos.loaded?
                    Orocos.load
                end
                Orocos.master_project.extend(MasterProjectHook)

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

                all_files =
                    app.find_files_in_dirs("models", "orogen", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.orogen$/)
                all_files.each do |path|
                    name = File.basename(path, ".orogen")
                    if !Orocos.available_projects.has_key?(name)
                        Orocos.master_project.register_orogen_file(path, name)
                    end
                end

                # Load the data services and task models
                all_files =
                    app.find_files_in_dirs("models", "blueprints", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("tasks", "compositions", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("models", "compositions", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/)
                    app.find_files_in_dirs("tasks", "data_services", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("models", "data_services", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("tasks", "compositions", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                    app.find_files_in_dirs("models", "compositions", "ROBOT", :all => true, :order => :specific_last, :pattern => /\.rb$/)
                all_files.each do |path|
                    app.require(path)
                end
            end

            # Load the specified oroGen project and register the task contexts
            # and deployments they contain.
            def using_task_library(name)
                names.each do |n|
                    orogen = Orocos.master_project.using_task_library(n)
                    if !loaded_orogen_project?(n)
                        # The project was already loaded on
                        # Orocos.master_project before Roby kicked in. Just load
                        # the Roby part
                        import_orogen_project(n, orogen)
                    end
                end
            end

            def orocos_clear_models
                projects = Set.new

                all_models = Component.submodels | DataService.submodels | Deployment.submodels
                all_models.each do |model|
                    next if model.permanent_model?
                    valid_name =
                        begin
                            constant(model.name) == model
                        rescue NameError
                        end

                    if valid_name
                        parent_module =
                            if model.name =~ /::/
                                model.name.gsub(/::[^:]*$/, '')
                            else Object
                            end
                        constant(parent_module).send(:remove_const, model.name.gsub(/.*::/, ''))
                    end
                end

                Component.clear_submodels
                DataService.clear_submodels
                Deployment.clear_submodels
                Orocos.clear

                loaded_orogen_projects.clear
            end

            def self.load_task_extension(file, app)
                relative_path = Roby.app.make_path_relative(file)
                if file != relative_path
                    $LOADED_FEATURES << relative_path
                end

                begin
                    app.require file
                rescue Exception
                    $LOADED_FEATURES.delete(relative_path)
                    raise
                end
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
                register_process_server('localhost', client, Roby.app.log_dir)
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
                server   = Roby::Conf.process_server_for(options[:on])
                deployer = server.load_orogen_deployment(name)

                if !loaded_orogen_project?(deployer.project.name)
                    # The project was already loaded on
                    # Orocos.master_project before Roby kicked in. Just load
                    # the Roby part
                    import_orogen_project(deployer.project.name, deployer.project)
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

                model = Deployment.model_for(name)
                deployments[options[:on]] << model
                model
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

            def self.plug_engine_in_roby(roby_engine)
                handler_ids = []
                handler_ids << roby_engine.add_propagation_handler(:type => :external_events, &Runtime.method(:update_task_states))
                handler_ids << roby_engine.add_propagation_handler(:type => :propagation, :late => true, &Runtime::ConnectionManagement.method(:update))
                handler_ids
            end

            def self.unplug_engine_from_roby(handler_ids, roby_engine)
                handler_ids.each do |handler_id|
                    roby_engine.remove_propagation_handler(handler_id)
                end
            end

            def self.run(app)
                if has_local_process_server?
                    connect_to_local_process_server
                end

                handler_ids = plug_engine_in_roby(Roby.engine)

                if app.orocos_start_all_deployments?
                    all_deployment_names = app.orocos_engine.deployments.values.map(&:to_a).flatten
                    Roby.execute do
                        all_deployment_names.each do |name|
                            task = Deployment.model_for(name).instanciate(Roby.app.orocos_engine)
                            app.plan.add_permanent(task)
                        end
                    end
                end

                yield

            ensure
                remaining = Orocos.each_process.to_a
                if !remaining.empty?
                    Syskit.warn "killing remaining Orocos processes: #{remaining.map(&:name).join(", ")}"
                    Orocos::Process.kill(remaining)
                end

                if handler_ids
                    unplug_engine_from_roby(handler_ids, Roby.engine)
                end
            end

            def self.cleanup(app)
		app.orocos_clear_models
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
        end
    end
end

