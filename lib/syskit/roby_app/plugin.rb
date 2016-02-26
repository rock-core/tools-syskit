class Module
    def backward_compatible_constant(old_name, new_constant, file)
        msg = "  #{self.name}::#{old_name} has been renamed to #{new_constant} and is now in #{file}"
        if Roby.app.backward_compatible_naming?
            Syskit.warn msg
            require file
            const_set old_name, constant(new_constant)
        else
            Syskit.error msg 
            Syskit.error "set Roby.app.backward_compatible_naming = true to reenable. This option will be removed in the future, so start using the new name and file"
        end
    end
end

module Syskit
    def self.warn_about_new_naming_convention
        Syskit.warn 'We have finally adopted a systematic naming convention in Syskit, this led to files and classes to be renamed'
    end
end

module Syskit
    module RobyApp
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Plugin
            def default_loader
                if !@default_loader
                    @default_loader = Orocos.default_loader
                    default_loader.on_project_load do |project|
                        project_define_from_orogen(project)
                    end
                    orogen_pack_loader
                    ros_loader
                end
                @default_loader
            end

            def orogen_pack_loader
                @orogen_pack_loader ||= OroGen::Loaders::Files.new(default_loader)
            end

            def ros_loader
                @ros_loader ||= OroGen::ROS::Loader.new(default_loader)
            end

            def default_orogen_project
                @default_orogen_project ||= OroGen::Spec::Project.new(default_loader)
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

                if app.testing?
                    require 'syskit/test'
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

                tasks = orogen.self_tasks.each_value.map do |task_def|
                    syskit_model =
                        if !TaskContext.has_model_for?(task_def)
                            Syskit::TaskContext.define_from_orogen(task_def, register: true)
                        else
                            Syskit::TaskContext.model_for(task_def)
                        end

                    syskit_model.configuration_manager.reload
                    syskit_model
                end


                if file = load_component_extension(orogen.name)
                    tasks.each do |t|
                        t.definition_location = [[file,0,nil]]
                        t.extension_file = file
                    end
                end

                orogen
            end

            # Load the component extension file associated with this an oroGen
            # project
            #
            # @param [String] name the orogen project name
            # @return [String,nil] either a file that got required, or nil if
            #   none was
            def load_component_extension(name)
                # If we are loading under Roby, get the plugins for the orogen
                # project
                return if !Syskit.conf.load_component_extensions?
                    
                file = find_file('models', 'orogen', "#{name}.rb", order: :specific_first) ||
                    find_file('tasks', 'orogen', "#{name}.rb", order: :specific_first) ||
                    find_file('tasks', 'components', "#{name}.rb", order: :specific_first)
                return if !file

                Roby::Application.info "loading task extension #{file}"
                if require(file)
                    file
                end
            end

            # If true, syskit is loading all available oroGen projects on this
            # system. It is set automatically by #syskit_load_all to ensure that
            # everything is reloaded when the app reloads its models
            attr_predicate :auto_load_all_task_libraries?, true

            # Loads all available oroGen projects
            def auto_load_all_task_libraries
                self.auto_load_all_task_libraries = true
                default_loader.each_available_project_name do |name|
                    using_task_library(name)
                end
            end

            def self.setup_loaders(app)
                all_files =
                    app.find_files_in_dirs("models", "ROBOT", "pack", "orogen", :all => app.auto_load_all?, :order => :specific_first, :pattern => /\.orogen$/)
                all_files.reverse.each do |path|
                    name = File.basename(path, ".orogen")
                    app.orogen_pack_loader.register_orogen_file path, name
                end

                all_files =
                    app.find_files_in_dirs("models", "ROBOT", "pack", "orogen", :all => app.auto_load_all?, :order => :specific_first, :pattern => /\.typelist$/)
                all_files.reverse.each do |path|
                    name = File.basename(path, ".typelist")
                    dir  = File.dirname(path)
                    app.orogen_pack_loader.register_typekit dir, name
                end

                app.ros_loader.search_path.
                    concat(Roby.app.find_dirs('models', 'ROBOT', 'orogen', 'ros', :all => app.auto_load_all?, :order => :specific_first))
                app.ros_loader.packs.
                    concat(Roby.app.find_dirs('models', 'ROBOT', 'pack', 'ros', :all => true, :order => :specific_last))
            end

            # Called by the main Roby application on setup. This is the first
            # configuration step.
            def self.setup(app)
                # We have our own loader, avoid clashing
                Orocos.default_loader.export_types = false
                # But, for the time being, default_loader might be equal to
                # Orocos.default_loader, so reset the export_types flag to the
                # desired value
                app.default_loader.export_types = Syskit.conf.export_types?

                # This is a HACK. We should be able to specify it differently
                if app.testing? && app.auto_load_models?
                    app.auto_load_all_task_libraries = true
                end

                setup_loaders(app)

                if app.shell?
                    return
                end

                Orocos.configuration_log_name = File.join(app.log_dir, 'properties')
                Orocos.disable_sigchld_handler = true

                Syskit.conf.register_process_server(
                    'ruby_tasks', Orocos::RubyTasks::ProcessManager.new(app.default_loader), app.log_dir)

                Syskit.conf.register_process_server(
                    'unmanaged_tasks', UnmanagedTasksManager.new, app.log_dir)

                Syskit.conf.register_process_server(
                   'ros', Orocos::ROS::ProcessManager.new(app.ros_loader), app.log_dir)

                ENV['ORO_LOGFILE'] = File.join(app.log_dir, "orocos.orocosrb-#{::Process.pid}.txt")
                if Syskit.conf.only_load_models?
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
                    end
                end

                start_local_process_server = !Syskit.conf.only_load_models? &&
                    !Syskit.conf.disables_process_server? &&
                    !(app.single? && app.simulation?)

                if start_local_process_server
                    start_local_process_server(:redirect => Syskit.conf.redirect_local_process_server?)
                else
                    fake_client = Configuration::ModelOnlyServer.new(app.default_loader)
                    Syskit.conf.register_process_server('localhost', fake_client, app.log_dir)
                end

                rtt_core_model = app.default_loader.task_model_from_name("RTT::TaskContext")
                Syskit::TaskContext.define_from_orogen(rtt_core_model, :register => true)

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
            def self.clear_config(app)
                Syskit.conf.clear
                Syskit.conf.deployments.clear
            end

            def self.require_models(app)
                if has_local_process_server?
                    connect_to_local_process_server(app)
                end

                # Load the data services and task models
                search_path = app.auto_load_search_path
                if app.auto_load_models?
                    all_files =
                        app.find_files_in_dirs("models", "services", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                        app.find_files_in_dirs("models", "devices", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
                        app.find_files_in_dirs("models", "compositions", "ROBOT", :path => search_path, :all => true, :order => :specific_last, :pattern => /\.rb$/) +
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

                   # Also require all the available oroGen projects
                   app.default_loader.each_available_project_name do |name|
                       app.using_task_library name
                   end
                end
                if app.auto_load_all? || app.auto_load_all_task_libraries?
                    app.auto_load_all_task_libraries
                end
                app.isolate_load_errors("while reloading deployment definitions") do
                    Syskit.conf.reload_deployments
                end
            end

            def self.load_default_models(app)
                ['services.rb', 'devices.rb', 'compositions.rb', 'profiles.rb'].each do |root_file|
                    if path = app.find_file('models', root_file, path: [app.app_dir], order: :specific_first)
                        require path
                    end
                end
            end

            # Loads the required typekit model by its name
            def import_types_from(typekit_name)
                default_loader.typekit_model_from_name(typekit_name)
            end

            # Load the specified oroGen project and register the task contexts
            # and deployments they contain.
            #
            # @return [OroGen::Spec::Project]
            def using_task_library(name, options = Hash.new)
                options = Kernel.validate_options options, :loader => default_loader
                options[:loader].project_model_from_name(name)
            end

            # Loads the required ROS package
            def using_ros_package(name, options = Hash.new)
                options = Kernel.validate_options options, :loader => ros_loader
                using_task_library(name, options)
            end

            # @deprecated use {using_task_library} instead
            def load_orogen_project(name, options = Hash.new)
                using_task_library(name, options)
            end

            # Start a process server on the local machine, and register it in
            # Syskit.process_servers under the 'localhost' name
            def self.start_local_process_server(
                    port = Orocos::RemoteProcesses::DEFAULT_PORT, redirect: true)
                if Syskit.conf.process_servers['localhost']
                    raise ArgumentError, "there is already a process server called 'localhost' running"
                end

                if !File.exists?(Roby.app.log_dir)
                    FileUtils.mkdir_p(Roby.app.log_dir)
                end

                spawn_options = Hash[chdir: Roby.app.log_dir, pgroup: true]
                if redirect
                    spawn_options[:err] = :out
                    spawn_options[:out] = File.join(Roby.app.log_dir, 'local_process_server.txt')
                end

                @server_pid  = Kernel.spawn 'orocos_process_server', "--port=#{port}", "--debug", spawn_options
                @server_port = port
                nil
            end

            def self.has_local_process_server?
                @server_pid
            end

            def self.connect_to_local_process_server(app)
                if !@server_pid
                    raise Orocos::RemoteProcesses::Client::StartupFailed, "#connect_to_local_process_server got called but no process server is being started"
                end

                # Wait for the server to be ready
                client = nil
                while !client
                    client =
                        begin Orocos::RemoteProcesses::Client.new('localhost', @server_port)
                        rescue Errno::ECONNREFUSED
                            sleep 0.1
                            is_running = 
                                begin
                                    !::Process.waitpid(@server_pid, ::Process::WNOHANG)
                                rescue Errno::ESRCH
                                    false
                                end

                            if !is_running
                                raise Orocos::RemoteProcesses::Client::StartupFailed, "the local process server failed to start"
                            end
                            nil
                        end
                end

                # Verify that the server is actually ours (i.e. check that there
                # was not one that was still running)
                if client.server_pid != @server_pid
                    raise Orocos::RemoteProcesses::Client::StartupFailed, "failed to start the local process server. It seems that there is one still running as PID #{client.server_pid} (was expecting #{@server_pid})"
                end

                # Do *not* manage the log directory for that one ...
                Syskit.conf.register_process_server('localhost', client, app.log_dir)
            end

            # Loads the oroGen deployment model for the given name and returns
            # the corresponding syskit model
            def using_deployment(name, options = Hash.new)
                options = Kernel.validate_options options, :loader => default_loader
                deployer = options[:loader].deployment_model_from_name(name)
                deployment_define_from_orogen(deployer)
            end

            # Loads the oroGen deployment model based on a ROS launcher file
            def using_ros_launcher(name, options = Hash.new)
                options = Kernel.validate_options options, :loader => ros_loader
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
            end

            ##
            # :attr: local_only?
            #
            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            def self.roby_engine_propagation_handlers
                handlers = Hash.new
                handlers[:update_deployment_states] = [
                    Runtime.method(:update_deployment_states), type: :external_events, description: 'syskit:update_deployment_states']
                handlers[:update_task_states] = [
                    Runtime.method(:update_task_states), type: :external_events, description: 'syskit:update_task_states']
                handlers[:update] = [
                    Runtime::ConnectionManagement.method(:update), type: :propagation, late: true, description: 'syskit:connection_management_update']
                handlers[:apply_requirement_modifications] = [
                    Runtime.method(:apply_requirement_modifications), type: :propagation, late: true, description: 'syskit:apply_requirement_modifications']
                handlers
            end

            def self.plug_engine_in_roby(roby_engine)
                handler_ids = Hash.new
                roby_engine_propagation_handlers.each do |name, (m, options)|
                    handler_ids[name] = roby_engine.add_propagation_handler(options, &m)
                end
                handler_ids
            end

            def self.unplug_engine_from_roby(handler_ids = @handler_ids, roby_engine)
                handler_ids.delete_if do |handler_id|
                    roby_engine.remove_propagation_handler(handler_id)
                    true
                end
            end

            def self.unplug_handler_from_roby(roby_engine, *handlers)
                if @handler_ids
                    handlers.each do |h|
                        roby_engine.remove_propagation_handler(@handler_ids.delete(h))
                    end
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
                @handler_ids = plug_engine_in_roby(app.execution_engine)
            end


            def self.root_models
                [Syskit::Component, Syskit::Actions::Profile]
            end

            def self.clear_models(app)
                app.loaded_orogen_projects.clear
                app.default_loader.clear

                # We need to explicitly call Orocos.clear even though it looks
                # like clearing the process servers would be sufficient
                #
                # The reason is that #cleanup only disconnects from the process
                # servers, and is called before #clear_models. However, for
                # "fake" process servers, syskit also assumes that reconnecting
                # to a "new" local process server will have cleared all cached
                # values. This won't work as the process server will not be
                # cleared in addition of being disconnected
                #
                # I (sylvain) chose to not clear on disconnection as it sounds
                # too much like a very bad side-effect to me. Simply explicitly
                # clear the local registries here
                Orocos.clear

                # This needs to be cleared here and not in
                # Component.clear_model. The main reason is that we need to
                # clear them on every component model class,
                # including the models that are markes as permanent
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
                    unplug_engine_from_roby(@handler_ids.values, app.execution_engine)
                    @handler_ids = nil
                end

                disconnect_all_process_servers
                stop_local_process_server
            end

            # Disconnects from all process servers
            def self.disconnect_all_process_servers
                process_servers = Syskit.conf.each_process_server_config.map(&:name)
                process_servers.each do |name|
                    next if name =~ /-sim$/
                    ps = Syskit.conf.remove_process_server(name)
                    ps.client.disconnect
                end
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

                OroGen.load_orogen_plugins('syskit')
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(OroGen::OROGEN_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROCOSRB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Typelib::TYPELIB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Syskit::SYSKIT_LIB_DIR))
                toplevel_object.extend LoadToplevelMethods
            end

            def self.register_generators(app)
                RubiGen::Base.__sources << RubiGen::PathSource.new(:syskit, File.join(Syskit::SYSKIT_ROOT_DIR, "generators"))
            end

            def self.filter_test_files(app, files)
                files = files.find_all { |path| File.basename(path) != 'suite_orogen.rb' }
                orogen_tests = app.find_files_in_dirs(
                    'test', 'ROBOT', 'orogen',
                    path: [Roby.app.app_dir],
                    all: true,
                    order: :specific_first,
                    pattern: /^(?:suite_|test_).*\.rb$/)
                orogen_tests.each do |path|
                    orogen_project = File.basename(path, '.rb').gsub(/^test_/, '')
                    begin
                        app.using_task_library orogen_project
                        files << path
                    rescue OroGen::ProjectNotFound => e
                        Roby.warn "skipping #{path}: #{e}"
                    end
                end
                files
            end
        end
    end
end
Roby::Application.include Syskit::RobyApp::Plugin
Syskit::RobyApp::Plugin.toplevel_object = self
