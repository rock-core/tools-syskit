require 'utilrb/kernel/load_dsl_file'
require 'roby/state'
require 'utilrb/spawn'

require 'typelib'
module Typelib
    class CompoundType
    	def update(&block)
	    yield(self)
	end
    end
end

module Orocos
    module RobyPlugin
        module MasterProjectHook
            def register_loaded_project(name, project)
                super
                Roby.app.import_orogen_project(name, project)
            end
        end
        
        class LogGroup
            def load(&block)
                instance_eval(&block)
            end

            def initialize(enabled = true)
                @deployments = Set.new
                @tasks = Set.new
                @ports = Set.new
                @names = Set.new
                @enabled = enabled
            end

            attr_reader :deployments
            attr_reader :tasks
            attr_reader :ports
            attr_reader :names

            attr_predicate :enabled? , true

            # Adds +object+ to this logging group
            #
            # +object+ can be
            # * a deployment model, in which case no task  in this deployment
            #   will be logged
            # * a task model, in which case no port of any task of this type
            #   will be logged
            # * a [task_model, port_name] pair
            # * a string. It can then either be a task name, a port name or a type
            #   name
            def add(object, subname = nil)
                if object.kind_of?(Class) && object < RobyPlugin::DataService
                    if subname
                        ports << [object, subname]
                    else
                        tasks << object
                    end
                elsif object.kind_of?(Class) && object < RobyPlugin::Deployment
                    deployments << object
                else
                    names << object.to_str
                end
            end

            def matches_deployment?(deployment)
                if deployments.include?(deployment.model)
                    true
                elsif names.include?(deployment.name)
                    true
                else
                    false
                end
            end

            def matches_port?(deployment, task_model, port)
                if ports.any? { |model, port_name| port.name == port_name && task_model.fullfills?(model) }
                    true
                elsif tasks.include?(task_model)
                    true
                elsif deployments.include?(deployment.model)
                    true
                else
                    names.include?(port.type_name) ||
                        names.include?(port.task.name) ||
                        names.include?(port.name) ||
                        names.include?("#{port.task.name}.#{port.name}")
                end
            end
        end

        # Orocos engine configuration interface
        #
        # The main instance of this object can be accessed as Roby::Conf.orocos. For
        # instance,
        #
        #   Roby::Conf.orocos.disable_logging
        #
        # will completely disable logging (not recommended !)
        class Configuration
            include Roby::ExtendedStruct
            def initialize
                initialize_extended_struct(Roby::ExtendedStruct)
                super

                @log_enabled = true
                @conf_log_enabled = true
                @redirect_local_process_server = true

                @log_groups = { nil => LogGroup.new(false) }

                registry = Typelib::Registry.new
                Typelib::Registry.add_standard_cxx_types(registry)
                registry.each do |t|
                    if t < Typelib::NumericType
                        main_group.names << t.name
                    end
                end
            end

            # The set of currently defined log groups
            #
            # It is a mapping from the log group name to the corresponding
            # LogGroup instance
            attr_reader :log_groups

            # The main log filter
            #
            # See #log_group
            def main_group
                log_groups[nil]
            end

            # Create a new log group with the given name
            #
            # A log groups are sets of filters that are used to match
            # deployments, tasks or specific ports. These filters can be enabled
            # or disabled using their name with #enable_log_group and
            # #disable_log_group
            def log_group(name, &block)
                group = LogGroup.new
                group.load(&block)
                log_groups[name.to_str] = group
            end

            # Exclude +object+ from the logging system
            #
            # +object+ can be
            # * a deployment model, in which case no task  in this deployment
            #   will be logged
            # * a task model, in which case no port of any task of this type
            #   will be logged
            # * a port model, in which case no such port will be logged
            #   (regardless of which task it is on)
            # * a string. It can then either be a task name, a port name or a type
            #   name
            def exclude_from_log(object, subname = nil)
                main_group.add(object, subname)
            end

            def enable_log_group(name)
	        name = name.to_s
	        if !log_groups.has_key?(name)
		    raise ArgumentError, "no such log group #{name}. Available groups are: #{log_groups.keys.join(", ")}"
		end
                log_groups[name].enabled = true
            end

            def disable_log_group(name)
	        name = name.to_s
	        if !log_groups.has_key?(name)
		    raise ArgumentError, "no such log group #{name}. Available groups are: #{log_groups.keys.join(", ")}"
		end
                log_groups[name].enabled = false
            end

            # If true, the output of the local process server will be saved in
            # log_dir/local_process_server.txt
            attr_predicate :redirect_local_process_server?, true

            # Signifies whether orocos logging is enabled at all or not. If
            # false, no logging will take place. If true, logging is enabled to
            # the extent of the log configuration done with enable/disable log
            # groups (#enable_log_group) and single ports (#exclude_from_log)
            attr_predicate :log_enabled?
            # See #log_enabled?
            def enable_logging; @log_enabled = true end
            # See #log_enabled?
            def disable_logging; @log_enabled = false end

            # If true, changes to the values in properties are being logged by
            # the framework. If false, they are not.
            #
            # Currently, properties are logged in a properties.0.log file
            attr_predicate :conf_log_enabled?
            # See #conf_log_enabled?
            def enable_conf_logging; @conf_log_enabled = true end
            # See #conf_log_enabled?
            def disable_conf_logging; @conf_log_enabled = false end

            # Returns true if +deployment+ is completely excluded from logging
            def deployment_excluded_from_log?(deployment)
                if !log_enabled?
                    true
                else
                    matches = log_groups.find_all { |_, group| group.matches_deployment?(deployment) }
                    !matches.empty? && matches.all? { |_, group| !group.enabled? }
                end
            end

            # Returns true if the port with name +port_name+ of task model
            # +task_model+ in deployment +deployment+ should be logged or not
            def port_excluded_from_log?(deployment, task_model, port)
                if !log_enabled?
                    true
                else
                    matches = log_groups.find_all { |_, group| group.matches_port?(deployment, task_mode, port) }
                    !matches.empty? && matches.all? { |_, group| !group.enabled? }
                end
            end
        end

        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Application
            attr_predicate :orocos_auto_configure?, true

            def self.resolve_constants(const_name, context, namespaces)
                candidates = ([context] + namespaces).
                    compact.
                    find_all do |namespace|
                        namespace.const_defined_here?(const_name)
                    end

                if candidates.size > 1 && candidates.first != context
                    raise "#{const_name} can refer to multiple models: #{candidates.map { |mod| "#{mod.name}::#{const_name}" }.join(", ")}. Please choose one explicitely"
                elsif candidates.empty?
                    raise NameError, "uninitialized constant #{const_name}", caller(3)
                end
                candidates.first.const_get(const_name)
            end

            module RobotExtension
                def each_device(&block)
                    Roby.app.orocos_engine.robot.devices.each_value(&block)
                end

                def devices(&block)
                    if block
                        Kernel.dsl_exec(Roby.app.orocos_engine.robot, RobyPlugin.constant_search_path, !Roby.app.filter_backtraces?, &block)
			Roby.app.orocos_engine.export_devices_to_planner(::MainPlanner)
                    else
                        each_device
                    end
                end
            end

            # The set of loaded orogen projects, as a mapping from the project
            # name to the corresponding TaskLibrary instance
            #
            # See #load_orogen_project.
            attribute(:loaded_orogen_projects) { Hash.new }
            # A mapping from task context model name to the corresponding
            # subclass of Orocos::RobyPlugin::TaskContext
            attribute(:orocos_tasks) { Hash.new }
            # A mapping from deployment name to the corresponding
            # subclass of Orocos::RobyPlugin::Deployment
            attribute(:orocos_deployments) { Hash.new }

            def main_orogen_project
                Orocos.master_project
            end

            # The system model object
            attr_accessor :orocos_system_model
            # The orocos engine we are using
            attr_accessor :orocos_engine
            # If true, we will not load the component-specific code in
            # tasks/orocos/
            attr_predicate :orocos_load_component_extensions, true

            def self.load(app, options)
                app.orocos_load_component_extensions = true

                ::Robot.extend Application::RobotExtension

                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(Orocos::OROGEN_LIB_DIR))
                Roby.app.filter_out_patterns << Regexp.new(Regexp.quote(File.expand_path('..', File.dirname(__FILE__))))
            end

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.has_key?(name) end
            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            def load_orogen_project(name, orogen = nil)
                if !orogen
                    Orocos.master_project.load_orogen_project(name)
                else
                    import_orogen_project(name, orogen)
                end
            end

            def import_orogen_project(name, orogen)
                return loaded_orogen_projects[name] if loaded_orogen_project?(name)

                if Orocos.available_task_libraries[name].respond_to?(:to_str)
                    orogen_path = Orocos.available_task_libraries[name]
                    if File.file?(orogen_path)
                        main_orogen_project.register_orogen_file(Orocos.available_task_libraries[name], name)
                    end
                end
                orogen ||= main_orogen_project.load_orogen_project(name)

                # If it is a task library, register it on our main project
                if !orogen.self_tasks.empty?
                    main_orogen_project.using_task_library(name)
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
                    if !orocos_tasks[task_def.name]
                        Orocos::RobyPlugin::TaskContext.define_from_orogen(task_def, orocos_system_model)
                    end
                end
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install? && !orocos_deployments[deployment_def.name]
                        orocos_deployments[deployment_def.name] = Orocos::RobyPlugin::Deployment.define_from_orogen(deployment_def)
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

                # Finally, import in the Orocos namespace directly
                const_name = name.camelcase(:upper)
                if !orogen.self_tasks.empty?
                    Orocos.const_set(const_name, Orocos::RobyPlugin.const_get(const_name))
                end

                orogen
            end

            # Searches for the given file in OROCOS_ROBY_MODEL_PATH, if the
            # environment variable is set.
            #
            # Returns the first file found, if there is one, and otherwise
            # returns nil
            def self.find_in_model_path(*basename)
                if path = ENV['OROCOS_ROBY_MODEL_PATH']
                    path = path.split(':')
                    path.each do |p|
                        p = File.join(p, *basename)
                        if File.readable?(p)
                            return p
                        end
                    end
                    nil
                end
            end

            def get_orocos_task_model(spec)
                if spec.respond_to?(:to_str)
                    if model = orocos_tasks[spec]
                        return model
                    end
                    raise ArgumentError, "there is no orocos task model named #{spec}"
                elsif !(spec < TaskContext)
                    raise ArgumentError, "#{spec} is not a task context model"
                else
                    spec
                end
            end

            def orogen_load_all
                Orocos.available_projects.each_key do |name|
                    Orocos.master_project.load_orogen_project(name)
                end
            end

            attr_writer :redirect_local_process_server
            def redirect_local_process_server?
                if @redirect_local_process_server.nil?
                    true
                else @redirect_local_process_server
                end
            end

            # Called by Roby::Application on setup
            def self.setup(app)
                if !Roby.respond_to?(:orocos_engine)
                    def Roby.orocos_engine
                        Roby.app.orocos_engine
                    end
                end

                [Kernel, Orocos].each do |mod|
                    if !mod.const_defined_here?('Cmp')
                        mod.const_set('Deployments',  Orocos::RobyPlugin::Deployments)
                        mod.const_set('DataServices', Orocos::RobyPlugin::DataServices)
                        mod.const_set('Srv',          Orocos::RobyPlugin::DataServices)
                        mod.const_set('Devices',      Orocos::RobyPlugin::Devices)
                        mod.const_set('Dev',          Orocos::RobyPlugin::Devices)
                        mod.const_set('Compositions', Orocos::RobyPlugin::Compositions)
                        mod.const_set('Cmp',          Orocos::RobyPlugin::Compositions)
                    end
                end

                if app.shell?
                    return
                end

                Roby::Conf.orocos = Configuration.new

                Orocos.configuration_log_name ||= File.join(app.log_dir, 'properties')
                app.orocos_auto_configure = true
                Orocos.disable_sigchld_handler = true

                app.orocos_system_model = SystemModel.new
                app.orocos_engine = Engine.new(app.plan || Roby::Plan.new, app.orocos_system_model)
                Orocos.singleton_class.class_eval do
                    attr_reader :engine
                end
                Orocos.instance_variable_set :@engine, app.orocos_engine

                # Change to the log dir so that the IOR file created by the
                # CORBA bindings ends up there
                Dir.chdir(app.log_dir) do
                    if !app.orocos_only_load_models?
                        Orocos.initialize
                    end

                    if !app.shell? && !app.orocos_disables_local_process_server?
                        start_local_process_server(:redirect => app.redirect_local_process_server?)
                    end
                end

                app.orocos_tasks['RTT::TaskContext'] = Orocos::RobyPlugin::TaskContext

                rtt_taskmodel = Orocos::Generation::Component.standard_tasks.
                    find { |m| m.name == "RTT::TaskContext" }
                Orocos::RobyPlugin::TaskContext.instance_variable_set :@orogen_spec, rtt_taskmodel
                Orocos::RobyPlugin.const_set :RTT, Module.new
                Orocos::RobyPlugin::RTT.const_set :TaskContext, Orocos::RobyPlugin::TaskContext
            end

            # Hook into the Application#require_config call directly, instead of
            # using the normal plugin-app system. We need that since we need to
            # load the config/ROBOT file ourselves using load_system_model
            def self.require_config(app)
                app.find_dirs('config', 'orogen', 'ROBOT', :all => true, :order => :specific_last).
                    each do |dir|
                        Orocos.conf.load_dir(dir)
                    end
            end

            def self.reload_config(app)
                if defined? ::MainPlanner
                    app.orocos_engine.robot.devices.each do |name, _|
                        if MainPlanner.has_method?("#{name}_device")
                            MainPlanner.remove_planning_method("#{name}_device")
                        end
                    end
                    app.orocos_engine.defines.each do |name, _|
                        if MainPlanner.has_method?(name)
                            MainPlanner.remove_planning_method(name)
                        end
                    end
                end

                app.orocos_engine.robot.clear
                app.orocos_engine.defines.clear
            end

            def self.require_models(app)
                if !Orocos.loaded?
                    Orocos.load
                end
                Orocos.master_project.extend(MasterProjectHook)

                Orocos::RobyPlugin.process_servers.each do |name, (client, log_dir)|
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
                    app.load_system_model(path)
                end

                # Define planning methods on the main planner for the available
                # deployment files
                app.find_files_in_dirs('config', 'deployments', 'ROBOT', :all => true, :order => :specific_last, :pattern => /\.rb$/).each do |path|
                    name = File.basename(path, '.rb')
                    if !::MainPlanner.has_method?(name)
                        ::MainPlanner.describe "resets the current component network to the state defined in #{path}"
                        ::MainPlanner.method(name) do
                            RequirementModificationTask.new do |engine|
                                engine.clear
                                engine.load(path)
                            end
                        end
                    end
                end
            end

            def use_deployment(*args)
                orocos_engine.use_deployment(*args)
            end

            def use_deployments_from(*args)
                orocos_engine.use_deployments_from(*args)
            end

            def using_task_library(name)
                Roby.app.orocos_system_model.using_task_library(name)
            end

            def orocos_clear_models
                projects = Set.new

                orocos_tasks.each_value do |model|
                    if model.orogen_spec && model.orogen_spec.project.name
                        project_name = model.orogen_spec.project.name.camelcase(:upper)
                        task_name    = model.orogen_spec.basename.camelcase(:upper)
                        projects << project_name
                        constant("Orocos::RobyPlugin::#{project_name}").send(:remove_const, task_name)
                    end
                end
                orocos_tasks.clear

                orocos_deployments.each_key do |name|
                    name = name.camelcase(:upper)
                    Orocos::RobyPlugin::Deployments.send(:remove_const, name)
                end
                orocos_deployments.clear

                projects.each do |name|
                    name = name.camelcase(:upper)
                    Orocos::RobyPlugin.send(:remove_const, name)
                    if Orocos.const_defined_here?(name)
                        Orocos.send(:remove_const, name)
                    end
                end

                [DataServices, Compositions, Devices].each do |mod|
                    mod.constants.each do |const_name|
                        mod.send(:remove_const, const_name)
                    end
                end

                Orocos.clear

                loaded_orogen_projects.clear
            end

            def self.load_task_extension(file, app)
                relative_path = Roby.app.make_path_relative(file)
                if file != relative_path
                    $LOADED_FEATURES << relative_path
                end

                begin
                    if Kernel.load_dsl_file(file, Roby.app.orocos_system_model, RobyPlugin.constant_search_path, !Roby.app.filter_backtraces?)
                        RobyPlugin.info "loaded #{file}"
                    end
                rescue Exception
                    $LOADED_FEATURES.delete(relative_path)
                    raise
                end
            end

            # Load a part of the system model, i.e. composition and/or data
            # services
            def load_system_model(file)
                candidates = [file, "#{file}.rb"]
                candidates << File.join("models", "ROBOT", file)
                candidates << File.join("models", "ROBOT", "#{file}.rb")
                search_options = {:order => :specific_first}
                candidates = candidates.map do |path|
                    path = Pathname.new(path)
                    if path.absolute?
                        args = [path.to_s]
                    else
                        args = path.enum_for(:each_filename).to_a
                    end
                    args << search_options
                    find_file(*args)
                end.compact
                if candidates.empty?
                    raise ArgumentError, "there is no system model file called #{file}"
                end

                path = candidates.first
                Roby::Application.info "loading system model file #{path}"
                orocos_system_model.load(path)
            end

            # Load a part of the system definition, i.e. the robot description
            # files
            def load_system_definition(file)
                orocos_engine.load_composite_file(file)
            end

            # Looks for a deployment called +name+ in the current installation
            def find_orocos_deployment(name)
                if File.file?(name)
                    name
                else
                    return find_file('config', 'deployments', 'ROBOT', "#{name}.rb", :order => :specific_first)
		end
            end

            # Loads the specified orocos deployment file
            #
            # The deployment can either be a file name in
            # config/deployments/, config/ROBOT/deployments or a full path to a
            # separate deployment file.
            def load_orocos_deployment(name)
                if file = find_orocos_deployment(name)
                    load_system_definition(file)
		else
		    raise ArgumentError, "cannot find a deployment named '#{name}'"
		end
            end

            # Load the specified orocos deployment file and apply it to the main
            # plan
            #
            # The deployment can either be a file name in
            # config/deployments/, config/ROBOT/deployments or a full path to a
            # separate deployment file.
            #
            # If a block is given, it is instance_eval'd in orocos_engine. I.e.,
            # it can be used to modify the loaded deployment.
            #
            # This method accepts the same options than Engine#resolve
	    def apply_orocos_deployment(name, options = Hash.new, &block)
                load_orocos_deployment(name)
                orocos_engine.instance_eval(&block) if block_given?
		orocos_engine.resolve(options)
	    end

            # Start a process server on the local machine, and register it in
            # Orocos::RobyPlugin.process_servers under the 'localhost' name
            def self.start_local_process_server(
                    options = Orocos::ProcessServer::DEFAULT_OPTIONS,
                    port = Orocos::ProcessServer::DEFAULT_PORT)

                options, server_options = Kernel.filter_options options, :redirect => true
                if Orocos::RobyPlugin.process_servers['localhost']
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


            def self.register_process_server(name, client, log_dir)
                Orocos::RobyPlugin.process_servers[name] = [client, log_dir]
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
                Orocos::RobyPlugin.process_servers.delete('localhost')
            end

            def require_planners
                super

		orocos_engine.export_defines_to_planner(::MainPlanner)
		orocos_engine.export_devices_to_planner(::MainPlanner)
            end

            ##
            # :attr: local_only?
            #
            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            # Call to add a process server to to the set of servers that can be
            # used by this plan manager
            #
            # If 'host' is set to localhost, it disables the automatic startup
            # of the local process server (i.e. sets
            # orocos_disables_local_process_server to false)
            def orocos_process_server(name, host, options = Hash.new)
                if single?
                    if orocos_disables_local_process_server?
                        return
                    else
                        client = Orocos::ProcessClient.new('localhost')
                        return Application.register_process_server(name, client, Roby.app.log_dir)
                    end
                end

                if local_only? && host != 'localhost'
                    raise ArgumentError, "in local only mode"
                elsif Orocos::RobyPlugin.process_servers[name]
                    raise ArgumentError, "there is already a process server called #{name} running"
                end

                options = Kernel.validate_options options, :port => ProcessServer::DEFAULT_PORT, :log_dir => 'logs', :result_dir => 'results'

                port = options[:port]
                if host =~ /^(.*):(\d+)$/
                    host = $1
                    port = Integer($2)
                end

                if host == 'localhost'
                    self.orocos_disables_local_process_server = true
                end

                client = Orocos::ProcessClient.new(host, port)
                client.save_log_dir(options[:log_dir], options[:result_dir])
                client.create_log_dir(options[:log_dir], Roby.app.time_tag)
                Application.register_process_server(name, client, options[:log_dir])
            end

            ##
            # :attr: reject_ambiguous_processor_deployments?
            #
            # If multiple deployments are available for a task, and this task is
            # not a device driver, the resolution engine will randomly pick one
            # if this flag is set to false (the default). If set to true, it
            # will generate an error
            attr_predicate :reject_ambiguous_processor_deployments?, true

            ##
            # :attr: orocos_only_load_models?
            #
            # In normal operations, the plugin initializes the CORBA layer,
            # which takes some time.
            #
            # In some tools, one only wants to manipulate models offline. In
            # which case we don't need to waste time initializing the layer.
            #
            # Set this value to true to avoid initializing the CORBA layer
            attr_predicate :orocos_only_load_models?, true

            ##
            # :attr: orocos_disables_local_process_server?
            #
            # In normal operations, a local proces server called 'localhost' is
            # automatically started on the local machine. If this predicate is
            # set to true, using self.orocos_disables_local_process_server = true), then
            # this will be disabled
            #
            # See also #orocos_process_server
            attr_predicate :orocos_disables_local_process_server?, true

            # If true, all deployments declared with use_deployment or
            # use_deployments_from are getting started at the very beginning of
            # the execution
            #
            # This greatly reduces latency during operations
            attr_predicate :orocos_start_all_deployments?, true

            def self.plug_engine_in_roby(roby_engine)
                handler_ids = []
                handler_ids << roby_engine.add_propagation_handler(:type => :external_events, &RobyPlugin.method(:update_task_states))
                handler_ids << roby_engine.add_propagation_handler(:type => :propagation, :late => true, &RuntimeConnectionManagement.method(:update))
                handler_ids << roby_engine.add_propagation_handler(:type => :propagation, :late => true, &RobyPlugin.method(:apply_requirement_modifications))
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
                            task = Roby.app.orocos_deployments[name].instanciate(Roby.app.orocos_engine)
                            app.plan.add_permanent(task)
                        end
                    end
                end

                yield

            ensure
                remaining = Orocos.each_process.to_a
                if !remaining.empty?
                    RobyPlugin.warn "killing remaining Orocos processes: #{remaining.map(&:name).join(", ")}"
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
                Orocos::RobyPlugin.process_servers.each_value do |client, options|
                    client.disconnect
                end
                Orocos::RobyPlugin.process_servers.clear
            end
        end
    end

    Roby::Application.register_plugin('orocos', Orocos::RobyPlugin::Application) do
        require 'orocos/roby'
        require 'orocos/process_server'
        Orocos.load_orogen_plugins('roby')
        Roby.app.filter_out_patterns.push(/^#{Regexp.quote(File.expand_path(File.dirname(__FILE__), ".."))}/)
    end
end

