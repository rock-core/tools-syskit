# frozen_string_literal: true

require "syskit/roby_app/log_transfer_integration/tmp_root_ca"

class Module
    def backward_compatible_constant(old_name, new_constant, file)
        msg = "  #{name}::#{old_name} has been renamed to #{new_constant} and is now in #{file}"
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
        Syskit.warn "We have finally adopted a systematic naming convention in Syskit, this led to files and classes to be renamed"
    end
end

module Syskit
    module RobyApp
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        #
        # When in development mode, it will emit the following UI events:
        #
        # syskit_orogen_config_changed::
        #   files under config/orogen/ have been modified, and this affects
        #   loaded models. In addition, a text notification is sent to inform
        #   a shell user
        module Plugin
            # Hook called by the main application in Application#load_base_config
            def self.load_base_config(app)
                options = app.options
                conf = Syskit.conf
                if options = options["syskit"]
                    conf.prefix = options["prefix"]
                    conf.exclude_from_prefixing.concat(options["exclude_from_prefixing"] || [])
                    conf.sd_domain = options["sd_domain"]
                    conf.publish_on_sd.concat(options["publish_on_sd"] || [])
                end

                if app.testing?
                    require "syskit/test"
                end

                Orocos.disable_sigchld_handler = true
            end

            # Hook called by the main application at the beginning of Application#setup
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

                require "orocos/async" if Conf.ui?

                if app.development_mode?
                    require "listen"
                    app.syskit_listen_to_configuration_changes
                end

                if app.testing?
                    Syskit.conf.logs.disable_conf_logging
                    Syskit.conf.logs.disable_port_logging
                end

                unless Syskit.conf.only_load_models?
                    Syskit.conf.logs.create_configuration_log(
                        File.join(app.log_dir, "properties")
                    )
                end

                if Syskit.conf.define_default_process_managers? && Syskit.conf.only_load_models?
                    fake_client = Configuration::ModelOnlyServer.new(app.default_loader)
                    Syskit.conf.register_process_server(
                        "ruby_tasks", fake_client, app.log_dir, host_id: "syskit"
                    )
                    Syskit.conf.register_process_server(
                        "unmanaged_tasks", fake_client, app.log_dir, host_id: "syskit"
                    )
                    Syskit.conf.register_process_server(
                        "ros", fake_client, app.log_dir, host_id: "syskit"
                    )
                elsif Syskit.conf.define_default_process_managers?
                    Syskit.conf.register_process_server("ruby_tasks",
                                                        Orocos::RubyTasks::ProcessManager.new(app.default_loader),
                                                        app.log_dir, host_id: "syskit")

                    Syskit.conf.register_process_server(
                        "unmanaged_tasks", UnmanagedTasksManager.new, app.log_dir
                    )

                    Syskit.conf.register_process_server(
                        "ros", Orocos::ROS::ProcessManager.new(app.ros_loader),
                        app.log_dir
                    )
                end

                ENV["ORO_LOGFILE"] =
                    Orocos.orocos_logfile ||
                    File.join(app.log_dir, "orocos.orocosrb-#{::Process.pid}.txt")

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

                start_local_process_server =
                    Syskit.conf.define_default_process_managers? &&
                    !Syskit.conf.only_load_models? &&
                    !Syskit.conf.disables_local_process_server? &&
                    !(app.single? && app.simulation?)

                if start_local_process_server
                    start_local_process_server(redirect: Syskit.conf.redirect_local_process_server?)
                    connect_to_local_process_server(app)
                else
                    fake_client = Configuration::ModelOnlyServer.new(app.default_loader)
                    Syskit.conf.register_process_server("localhost", fake_client, app.log_dir, host_id: "syskit")
                end

                rtt_core_model = app.default_loader.task_model_from_name("RTT::TaskContext")
                Syskit::TaskContext.define_from_orogen(rtt_core_model, register: true)

                ###################### FTP Spawn Server ######################
                tmp_root_ca = TmpRootCA.new

                # Create Hash for passing to PS password and certificate
                ps_log_transfer_data = Hash[ 
                    certifica: tmp_root_ca.cert,
                    password: tmp_root_ca.ca_password
                ]

                # Create equal Hash in Process Server code to
                # store Certificate and Password
                
                start_local_log_transfer_server(app.log_dir, user, password, certificate)
            end

            
            def self.start_local_log_transfer_server(tgt_dir, user, password, certificate)
                @log_transfer_server = Syskit::RobyApp::LogTransferServer::SpawnServer.new(tgt_dir, user, password, certificate)
            end

            # Hook called by the main application in Application#setup after
            # the main setup hooks have been called
            def self.require_models(app)
                setup_loaders(app)

                app.extra_required_task_libraries.each do |name|
                    app.using_task_library name
                end
                app.extra_required_typekits.each do |name|
                    app.import_types_from name
                end

                unless app.permanent_requirements.empty?
                    toplevel_object.extend SingleFileDSL
                    app.execution_engine.once do
                        app.permanent_requirements.each do |req|
                            app.plan.add_mission_task(req.as_plan)
                        end
                    end
                end
            end

            # Hook called by the main application to undo what
            # {.require_models} and {.setup} have done
            def self.cleanup(app)
                if app.development_mode?
                    app.syskit_remove_configuration_changes_listener
                end

                disconnect_all_process_servers
                stop_local_process_server
            end

            # Hook called by the main application to prepare for execution
            def self.prepare(app)
                @handler_ids = plug_engine_in_roby(app.execution_engine)
            end

            # Hook called by the main application to undo what {.prepare} did
            def self.shutdown(app)
                remaining = Orocos.each_process.to_a
                unless remaining.empty?
                    Syskit.warn "killing remaining Orocos processes: #{remaining.map(&:name).join(', ')}"
                    Orocos::Process.kill(remaining)
                end

                if @handler_ids
                    unplug_engine_from_roby(@handler_ids.values, app.execution_engine)
                    @handler_ids = nil
                end
            end

            def default_loader
                unless @default_loader
                    @default_loader = Orocos.default_loader
                    default_loader.on_project_load do |project|
                        project_define_from_orogen(project)
                    end
                    orogen_pack_loader
                    ros_loader
                end
                @default_loader
            end

            def default_pkgconfig_loader
                Orocos.default_pkgconfig_loader
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

            # A set of task libraries that should be imported when the application
            # gets reloaded
            #
            # This is used in the UIs to load and inspect task libraries even
            # if they are not part of the app's configuration
            attribute(:extra_required_task_libraries) { [] }

            # A set of typekits that should be imported when the application
            # gets reloaded
            #
            # This is used in the UIs to load and inspect types even
            # if they are not part of the app's configuration
            attribute(:extra_required_typekits) { [] }

            # @return [Hash<String,OroGen::Spec::Project>] the set of projects
            #   loaded so far
            attribute(:loaded_orogen_projects) { {} }

            # Set of requirements that should be added to the running system.
            # This is meant to be used only by "syskit scripts" through
            # SingleFileDSL
            #
            # @return [Array<InstanceRequirements>]
            attribute(:permanent_requirements) { [] }

            def self.finalize_model_loading(app)
                if toplevel_object.respond_to?(:global_profile)
                    app.app_module::Actions::Main.use_profile toplevel_object.global_profile
                end
            end

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name)
                loaded_orogen_projects.key?(name)
            end

            OroGenLocation = Struct.new :absolute_path, :lineno, :label

            # Registers all objects contained in a given oroGen project
            #
            # @param [OroGen::Spec::Project] orogen the oroGen project that
            #   should be added to the Syskit side
            def project_define_from_orogen(orogen)
                return if loaded_orogen_projects.key?(orogen.name)

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
                        t.definition_location = [OroGenLocation.new(file, 1, nil)]
                        t.extension_file = file
                    end
                end

                orogen.each_deployment do |deployer_model|
                    deployment_define_from_orogen(deployer_model)
                end
                orogen
            end

            def syskit_utility_component?(task_context)
                if defined?(OroGen::Logger::Logger)
                    task_context.kind_of?(OroGen::Logger::Logger)
                end
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
                return unless Syskit.conf.load_component_extensions?

                file = find_file("models", "orogen", "#{name}.rb", order: :specific_first) ||
                    find_file("tasks", "orogen", "#{name}.rb", order: :specific_first) ||
                    find_file("tasks", "components", "#{name}.rb", order: :specific_first)
                return unless file

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

                app.ros_loader.search_path
                   .concat(Roby.app.find_dirs("models", "ROBOT", "orogen", "ros", :all => app.auto_load_all?, :order => :specific_first))
                app.ros_loader.packs
                   .concat(Roby.app.find_dirs("models", "ROBOT", "pack", "ros", :all => true, :order => :specific_last))
            end

            def syskit_listen_to_configuration_changes
                dirs = find_dirs("config", "orogen", "ROBOT", all: true, order: :specific_last)
                return if dirs.empty?

                @conf_listener = Listen.to(*dirs) do |modified, added, removed|
                    if syskit_has_pending_configuration_changes?
                        notify "syskit", "INFO", "oroGen configuration files changed on disk. In the shell, reload with #reload_config and reconfigure affected running components with #redeploy"
                        ui_event "syskit_orogen_config_changed"
                    end
                end
                @conf_listener.start
            end

            def syskit_remove_configuration_changes_listener
                @conf_listener&.stop
            end

            # Verifies whether the configuration on disk and the configurations
            # currently loaded in the running deployments are identical
            def syskit_has_pending_configuration_changes?
                TaskContext.each_submodel do |model|
                    return true if model.configuration_manager.changed_on_disk?
                end
                false
            end

            # Reloads the configuration files
            #
            # This only modifies the configuration loaded internally, but does
            # not change the configuration of existing task contexts. The new
            # configuration will only be applied after the next deployment
            #
            # @return [(Array,Array)] the names of the components whose configuration
            #   changed, and the subset of those that are currently running
            #
            # @see syskit_pending_reloaded_configurations
            def syskit_reload_config
                needs_reconfiguration = []
                running_needs_reconfiguration = []
                TaskContext.each_submodel do |model|
                    next unless model.concrete_model?

                    changed_sections = model.configuration_manager.reload
                    plan.find_tasks(Deployment).each do |deployment_task|
                        deployment_task.mark_changed_configuration_as_not_reusable(
                            model => changed_sections
                        ).each do |orocos_name|
                            needs_reconfiguration << orocos_name
                            deployment_task.each_executed_task do |t|
                                if t.orocos_name == orocos_name
                                    running_needs_reconfiguration << orocos_name
                                end
                            end
                            notify "syskit", "INFO", "task #{orocos_name} needs reconfiguration"
                        end
                    end
                end

                unless running_needs_reconfiguration.empty?
                    notify "syskit", "INFO", "#{running_needs_reconfiguration.size} running tasks configuration changed. In the shell, use 'redeploy' to trigger reconfiguration."
                end
                ui_event "syskit_orogen_config_reloaded", needs_reconfiguration,
                         running_needs_reconfiguration
                needs_reconfiguration
            end

            # Returns the names of the TaskContext that will need to be reconfigured
            # on the next deployment (either #redeploy or transition)
            #
            # @return [(Array,Array)] the list of all task names for tasks whose
            #   configuration has changed, and the subset of these tasks that are
            #   currently running
            def syskit_pending_reloaded_configurations
                pending_reconfigurations = []
                pending_running_reconfigurations = []
                plan.find_tasks(Deployment).each do |deployment_task|
                    pending = deployment_task.pending_reconfigurations
                    deployment_task.each_executed_task do |t|
                        if pending.include?(t.orocos_name)
                            pending_running_reconfigurations << t.orocos_name
                        end
                    end
                    pending_reconfigurations.concat(pending)
                end
                [pending_reconfigurations, pending_running_reconfigurations]
            end

            # Called by the main Roby application to clear all before redoing a
            # setup
            def self.clear_config(app)
                Syskit.conf.clear
            end

            def self.auto_require_models(app)
                # Load the data services and task models
                prefixes = %w[services devices compositions profiles]
                if Roby.app.backward_compatible_naming?
                    prefixes << "blueprints"
                end

                if Syskit.conf.ignore_missing_orogen_projects_during_load?
                    ignored_exceptions = [OroGen::NotFound]
                end
                prefixes.each do |prefix_name|
                    app.load_all_model_files_in(
                        prefix_name, ignored_exceptions: ignored_exceptions
                    )
                end

                # Also require all the available oroGen projects
                app.default_loader.each_available_project_name do |name|
                    app.using_task_library name
                end

                if app.auto_load_all? || app.auto_load_all_task_libraries?
                    app.auto_load_all_task_libraries
                end
            end

            def self.load_default_models(app)
                ["services.rb", "devices.rb", "compositions.rb", "profiles.rb"].each do |root_file|
                    if path = app.find_file("models", root_file, path: [app.app_dir], order: :specific_first)
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
            def using_task_library(name, options = {})
                options = Kernel.validate_options options, :loader => default_loader
                options[:loader].project_model_from_name(name)
            end

            # Loads the required ROS package
            def using_ros_package(name, options = {})
                options = Kernel.validate_options options, :loader => ros_loader
                using_task_library(name, options)
            end

            # @deprecated use {using_task_library} instead
            def load_orogen_project(name, options = {})
                using_task_library(name, options)
            end

            def autodiscover_tests_in?(path)
                if File.basename(path) == "orogen"
                    search_path.each do |base_path|
                        if File.join(base_path, "test", "orogen") == path
                            return false
                        end
                    end
                end

                if defined? super
                    super
                else true
                end
            end

            # Start a process server on the local machine, and register it in
            # Syskit.process_servers under the 'localhost' name
            def self.start_local_process_server(port = 0, redirect: true)
                if Syskit.conf.process_servers["localhost"]
                    raise ArgumentError, "there is already a process server called 'localhost' running"
                end

                unless File.exist?(Roby.app.log_dir)
                    FileUtils.mkdir_p(Roby.app.log_dir)
                end

                tcp_server = TCPServer.new("127.0.0.1", 0)
                spawn_options = Hash[tcp_server => tcp_server, chdir: Roby.app.log_dir, pgroup: true]
                if redirect
                    spawn_options[:err] = :out
                    spawn_options[:out] = File.join(Roby.app.log_dir, "local_process_server.txt")
                end

                @server_pid  = Kernel.spawn \
                    "syskit", "process_server", "--fd=#{tcp_server.fileno}", "--log-dir=#{Roby.app.log_dir}", "--debug",
                    spawn_options
                @server_port = tcp_server.local_address.ip_port
                tcp_server.close
                nil
            end

            def self.has_local_process_server?
                @server_pid
            end

            def self.connect_to_local_process_server(app)
                unless @server_pid
                    raise Syskit::RobyApp::RemoteProcesses::Client::StartupFailed,
                          "#connect_to_local_process_server got called but "\
                          "no process server is being started"
                end

                # Wait for the server to be ready
                client = nil
                until client
                    client =
                        begin Syskit::RobyApp::RemoteProcesses::Client.new("localhost", @server_port)
                        rescue Errno::ECONNREFUSED
                            sleep 0.1
                            is_running =
                                begin
                                    !::Process.waitpid(@server_pid, ::Process::WNOHANG)
                                rescue Errno::ESRCH
                                    false
                                end

                            unless is_running
                                raise Syskit::RobyApp::RemoteProcesses::Client::StartupFailed,
                                      "the local process server failed to start"
                            end

                            nil
                        end
                end

                # Verify that the server is actually ours (i.e. check that there
                # was not one that was still running)
                if client.server_pid != @server_pid
                    raise Syskit::RobyApp::RemoteProcesses::Client::StartupFailed,
                          "failed to start the local process server. It seems that "\
                          "there is one still running as PID #{client.server_pid} "\
                          "(was expecting #{@server_pid})"
                end

                # Do *not* manage the log directory for that one ...
                Syskit.conf.register_process_server("localhost", client, app.log_dir)
                client
            end

            # Stop the process server started by start_local_process_server if
            # one is running
            def self.stop_local_process_server
                return unless has_local_process_server?

                ::Process.kill("INT", @server_pid)
                begin
                    ::Process.waitpid(@server_pid)
                    @server_pid = nil
                rescue Errno::ESRCH
                end
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

            # Loads the oroGen deployment model for the given name and returns
            # the corresponding syskit model
            def using_deployment(name, loader: default_loader)
                # This loads the underlying orogen project which causes the
                # deployer to be registered
                deployment_model = loader.deployment_model_from_name(name)
                Deployment.find_model_by_orogen(deployment_model)
            end

            # Loads the oroGen deployment model based on a ROS launcher file
            def using_ros_launcher(name, options = {})
                options = Kernel.validate_options options, :loader => ros_loader
                using_deployment(name, options)
            end

            # Start all deployments
            #
            # @param [String,nil] on the name of the process server on which
            #   deployments should be started. If nil, all servers are considered
            def syskit_start_all_deployments(on: nil, except_on: "unmanaged_tasks")
                existing_deployments = plan.find_tasks(Syskit::Deployment)
                                           .not_finished
                                           .find_all(&:reusable?)
                                           .map(&:process_name).to_set

                Syskit.conf.each_configured_deployment(on: on, except_on: except_on) do |configured_deployment|
                    next if existing_deployments.include?(configured_deployment.process_name)

                    plan.add_permanent_task(configured_deployment.new)
                end
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
                    Deployment.define_from_orogen(deployer, register: true)
                end
            end

            ##
            # :attr: local_only?
            #
            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            def self.roby_engine_propagation_handlers
                handlers = {}
                handlers[:update_deployment_states] = [
                    Runtime.method(:update_deployment_states), type: :external_events, description: "syskit:update_deployment_states"
                ]
                handlers[:update_task_states] = [
                    Runtime.method(:update_task_states), type: :external_events, description: "syskit:update_task_states"
                ]
                handlers[:connection_management] = [
                    Runtime::ConnectionManagement.method(:update), type: :propagation, late: true, description: "syskit:connection_management_update"
                ]
                handlers[:apply_requirement_modifications] = [
                    Runtime.method(:apply_requirement_modifications), type: :propagation, late: true, description: "syskit:apply_requirement_modifications"
                ]
                handlers
            end

            def self.plug_engine_in_roby(roby_engine)
                handler_ids = {}
                roby_engine_propagation_handlers.each do |name, (m, options)|
                    handler_ids[name] = roby_engine.add_propagation_handler(**options, &m)
                end
                handler_ids
            end

            def self.unplug_engine_from_roby(handler_ids = @handler_ids, roby_engine)
                handler_ids.delete_if do |handler_id|
                    roby_engine.remove_propagation_handler(handler_id)
                    true
                end
            end

            def self.plug_handler_in_roby(roby_engine, *handlers)
                handlers.each do |handler_name|
                    m, options = roby_engine_propagation_handlers.fetch(handler_name)
                    next if @handler_ids.key?(handler_name)

                    @handler_ids[handler_name] = roby_engine.add_propagation_handler(options, &m)
                end
            end

            def self.unplug_handler_from_roby(roby_engine, *handlers)
                if @handler_ids
                    handlers.each do |h|
                        if h_id = @handler_ids.delete(h)
                            roby_engine.remove_propagation_handler(h_id)
                        end
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

            def self.root_models
                [Syskit::Component, Syskit::Actions::Profile]
            end

            def self.clear_models(app)
                OroGen.clear
                OroGen::Deployments.clear

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
                Syskit::Component.placeholder_models.clear
                Syskit::Component.each_submodel do |sub|
                    sub.placeholder_models.clear
                end

                # require_models is where the deployments get loaded, so
                # un-define them here
                Syskit.conf.clear_deployments
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

                OroGen.load_orogen_plugins("syskit")
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(OroGen::OROGEN_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROCOSRB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Typelib::TYPELIB_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Syskit::SYSKIT_LIB_DIR))
                toplevel_object.extend LoadToplevelMethods
            end

            class VariableSizedType < RuntimeError; end

            def self.validate_port_has_fixed_size(port, with_global_size, only_warn: false, ignore: [])
                return if with_global_size.include?(port.type)

                if fixed_size_type?(port.type) || globally_sized_type?(port.type)
                    with_global_size << port.type
                    return
                end

                port = port.to_component_port
                if ignore.include?(port.type)
                    nil
                elsif size = port.max_marshalling_size
                    size
                else
                    msg = "marshalled size of port #{port} cannot be inferred"
                    if only_warn
                        ::Robot.warn msg
                    else
                        raise VariableSizedType, msg
                    end
                end
            end

            def self.fixed_size_type?(type)
                !type.contains?(Typelib::ContainerType)
            end

            def self.globally_sized_type?(type)
                sizes = Orocos.max_sizes_for(type)
                !sizes.empty? && OroGen::Spec::Port.compute_max_marshalling_size(type, sizes)
            end

            def self.validate_all_port_types_have_fixed_size(only_warn: false, ignore: [])
                with_global_size = Set.new
                Syskit::Component.each_submodel do |component_m|
                    next if component_m.abstract?

                    component_m.each_input_port do |p|
                        validate_port_has_fixed_size(p, with_global_size, only_warn: only_warn, ignore: ignore)
                    end
                    component_m.each_output_port do |p|
                        validate_port_has_fixed_size(p, with_global_size, only_warn: only_warn, ignore: ignore)
                    end
                end
            end

            def self.setup_rest_interface(app, rest_api)
                require "syskit/roby_app/rest_api"
                rest_api.mount REST_API => "/syskit"
            end

        end
    end
end
Roby::Application.include Syskit::RobyApp::Plugin
Syskit::RobyApp::Plugin.toplevel_object = self
