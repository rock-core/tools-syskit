require 'orocos'
require 'utilrb/module/define_or_reuse'

module Orocos
    module RobyPlugin
        Generation = ::Orocos::Generation
        module Deployments
        end

        # Instances of Project are the namespaces into which the other
        # orocos-related objects (Deployment and TaskContext) are defined.
        #
        # For instance, the TaskContext sublass that represnets an imu::Driver
        # task context will be registered as Orocos::RobyPlugin::Imu::Driver
        class Project < Module
            # The instance of Orocos::Generation::TaskLibrary that contains the
            # specification information for this orogen project.
            attr_reader :orogen_spec
        end

        # Returns the Project instance that represents the given orogen project.
        def self.orogen_project_module(name)
            const_name = name.camelcase(true)
            Orocos::RobyPlugin.define_or_reuse(const_name) do
                mod = Project.new
                mod.instance_variable_set :@orogen_spec, ::Roby.app.loaded_orogen_projects[name]
                mod
            end
        end

        # In oroGen, a deployment is a Unix process that holds a certain number
        # of task contexts. This Roby task represents the unix process itself.
        # Once it gets instanciated, the associated task contexts can be
        # accessed with #task(name)
        class Deployment < ::Roby::Task
            attr_accessor :robot

            class << self
                # The Orocos::Generation::StaticDeployment that represents this
                # deployment.
                attr_reader :orogen_spec
            end
            def orogen_spec; self.class.orogen_spec end

            # The underlying Orocos::Process instance
            attr_reader :orogen_deployment

            # Returns the name of this particular deployment instance
            def self.deployment_name
                orogen_spec.name
            end

            # An array of Orocos::Generation::TaskDeployment instances that
            # represent the tasks available in this deployment. Associated plan
            # objects can be instanciated with #task
            def self.tasks
                orogen_spec.task_activities
            end

            def instanciate_all_tasks
                orogen_spec.task_activities.map do |act|
                    task(act.name)
                end
            end

            # Returns an task instance that represents the given task in this
            # deployment.
            def task(name)
                activity = orogen_spec.task_activities.find { |act| name == act.name }
                if !activity
                    raise ArgumentError, "no task called #{name} in #{self.class.deployment_name}"
                end

                klass = Roby.app.orocos_tasks[activity.context.name]
                task = klass.new
                task.robot = robot
                task.executed_by self
                task.instance_variable_set :@orogen_spec, activity
                if running?
                    task.orogen_task = begin ::Orocos::TaskContext.get(task.orocos_name)
                                       rescue NotFound
                                           STDERR.puts "WARN: #{task.orocos_name} cannot be found"
                                       end
                end
                task
            end

            ##
            # method: start!
            #
            # Starts the process and emits the start event immediately. The
            # :ready event will be emitted when the deployment is up and
            # running.
            event :start do
                @orogen_deployment = ::Orocos::Process.new(self.class.deployment_name)
                orogen_deployment.spawn(File.join(Roby.app.log_dir, "%m-%p.txt"))
                emit :start
            end

            # Event emitted when the deployment is up and running
            event :ready
            on :ready do
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orogen_task = begin ::Orocos::TaskContext.get(task.orocos_name)
                                       rescue NotFound
                                           STDERR.puts "WARN: #{task.orocos_name} cannot be found"
                                       end
                end
            end

            poll do
                if !ready?
                    if orogen_deployment.wait_running(0)
                        emit :ready
                    end
                elsif !orogen_deployment.running?
                    emit :failed
                end
            end

            ##
            # method: stop!
            #
            # Stops all tasks that are running on top of this deployment, and
            # kill the deployment
            event :stop do
                to_be_killed = each_executed_task.find_all { |task| task.running? }
                if to_be_killed.empty?
                    orogen_deployment.kill(false)
                    return
                end

                # Add an intermediate event that will fire when the intermediate
                # tasks have been stopped
                terminal = AndGenerator.new
                to_be_killed.each do |task|
                    task.stop!
                    terminal << task.stop_event
                end
                terminal.on { orogen_deployment.kill(false) }
                # The stop event will get emitted after the process has been
                # killed. See the polling block.
            end

            on :stop do
                each_parent_object(Roby::TaskStructure::ExecutionAgent) do |task|
                    task.orogen_task = nil
                end
            end

            # Creates a subclass of Deployment that represents the deployment
            # specified by +deployment_spec+.
            #
            # +deployment_spec+ is an instance of Orogen::Generation::Deployment
            def self.define_from_orogen(deployment_spec)
                klass = Class.new(Deployment)
                klass.instance_variable_set :@orogen_spec, deployment_spec
                Orocos::RobyPlugin::Deployments.const_set(deployment_spec.name.camelcase(true), klass)
                klass
            end
        end

        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update(plan) # :nodoc:
            if !(query = plan.instance_variable_get :@orocos_update_query)
                query = plan.find_tasks(Orocos::RobyPlugin::TaskContext)
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                if t.running? || t.starting?
                    t.update_orogen_state
                end

                if t.starting?
                    if t.orogen_state == :STOPPED && t.orogen_spec.needs_configuration?
                        t.orogen_task.start
                    end
                    if t.orogen_state != :STOPPED && t.orogen_state != :PRE_OPERATIONAL
                        t.emit :start
                    end
                end
            end
        end

        # In the orocos/rtt, a task context is what is usually called a
        # component.
        #
        # Subclasses of TaskContext represent these components in Roby plans,
        # and allow to control them.
        #
        # TaskContext instances may be associated with a Deployment task, that
        # represent the underlying deployment process. The link between a task
        # context and its deployment is usually represented by an executed_by
        # relation.
        class TaskContext < Component
            abstract

            extend Model

            class << self
                attr_reader :name
                # The Orocos::Generation::StaticDeployment that represents this
                # task context.
                attr_reader :orogen_spec
                # A mapping from state name to event name
                attr_reader :state_events
            end
            def state_event(name)
                self.class.state_events[name]
            end

            def ids; arguments[:ids] end

            def executable?
                !!@orogen_spec && super
            end

            attr_reader :minimal_period

            def self.triggered_by?(port)
                orogen_spec.event_ports.find { |p| p.name == port.name }
            end

            def trigger_latency
                orogen_spec.expected_trigger_latency
            end

            def update_minimal_period(period)
                if !@minimal_period || @minimal_period > period
                    @minimal_period = period
                end
            end

            # Computes the minimal update period from the activity alone. If it
            # is not possible (not enough information, or port-driven task for
            # instance), return nil
            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                if orogen_spec.activity_type == 'PeriodicActivity'
                    update_minimal_period(orogen_spec.period)
                end

                result
            end

            def propagate_ports_dynamics(result)
                STDERR.puts "propagating #{self}"
                handled_inputs = Set.new
                each_concrete_input_connection do |from_task, from_port, to_port, _|
                    next if !orogen_spec.context.event_ports.find { |p| p.name == to_port }
                    if result[self][to_port] && result[self][to_port].period
                        handled_inputs << to_port
                        next
                    end

                    STDERR.puts "  #{from_task}:#{from_port} => #{to_port}"
                    if result.has_key?(from_task) && (dynamics = result[from_task][from_port]) && dynamics.period
                        result[self][to_port] ||= PortDynamics.new
                        result[self][to_port].period = dynamics.period
                        handled_inputs << to_port
                        update_minimal_period(dynamics.period)
                    end
                end

                model.each_output do |port|
                    port_model = orogen_spec.context.port(port.name)

                    next if port_model.triggered_on_update?
                    periods = port_model.port_triggers.map do |trigger_port|
                        result[self][trigger_port.name]
                    end.compact.map(&:period).compact
                    if periods.size == port_model.port_triggers.size
                        result[self][port.name] ||= PortDynamics.new
                        result[self][port.name].period = periods.min * port.period
                    end
                end

                if handled_inputs.size == orogen_spec.context.event_ports.size
                    model.each_output do |port|
                        port_model = orogen_spec.context.port(port.name)
                        if port_model.triggered_on_update?
                            result[self][port.name] ||= PortDynamics.new
                            result[self][port.name].period = minimal_period * port.period
                        end
                    end

                    STDERR.puts to_s if !minimal_period
                    true
                else
                    remaining = orogen_spec.context.each_port.map(&:name).to_set
                    remaining -= result[self].keys.to_set
                    STDERR.puts("cannot find period information for " + remaining.to_a.join(", "))
                    false
                end
            end

            # The Orocos::TaskContext instance that gives us access to the
            # remote task context. Note that it is set only when the task is
            # started.
            attr_accessor :orogen_task
            # The Orocos::Generation::TaskDeployment instance that describes the
            # underlying task
            attr_reader :orogen_spec
            # The global name of the Orocos task underlying this Roby task
            def orocos_name; orogen_spec.name end
            # The current state for the orogen task
            attr_reader :orogen_state
            # The last read state
            attr_reader :last_state

            # Called at each cycle to update the orogen_state attribute for this
            # task.
            def update_orogen_state # :nodoc:
                if @state_reader && v = @state_reader.read
                    @orogen_state = v
                else
                    @orogen_state = orogen_task.state
                end
            end

            ##
            # :method: start!
            #
            # Optionally configures and then start the component. The start
            # event will be emitted when the it has successfully been
            # configured and started.
            event :start do
                if !(deployment = execution_agent)
                    raise "TaskContext tasks must be supported by a Deployment task"
                end

                if orogen_spec.extended_state_support?
                    @state_reader = orogen_task.state_reader
                end

                # We're not running yet, so we have to read the state ourselves.
                update_orogen_state

                if orogen_state != :PRE_OPERATIONAL && orogen_state != :STOPPED
                    raise "wrong state"
                end

                if orogen_state == :PRE_OPERATIONAL
                    orogen_task.configure
                else orogen_task.start
                end
                @last_state = nil
            end

            poll do
                if @last_state != orogen_state
                    handle_state_changes
                end
                @last_state = orogen_state
            end

            # Handle a state transition by emitting the relevant events
            def handle_state_changes # :nodoc:
                if orogen_task.error_state?(orogen_state)
                    @stopping_because_of_error = true
                    @stopping_origin = orogen_state
                    if orogen_task.fatal_error_state?(orogen_state)
                        orogen_task.reset_error
                    else
                        orogen_task.stop
                    end
                elsif orogen_state == :STOPPED
                    if @stopping_because_of_error
                        if event = state_event(@stopping_origin)
                            emit event
                        else
                            emit :failed
                        end
                    elsif interrupt?
                        emit :interrupt
                    else
                        emit :success
                    end
                elsif event = state_event(orogen_state)
                    emit event
                end
            end

            ##
            # :method: interrupt!
            #
            # Interrupts the execution of this task context
            event :interrupt do
                orogen_task.stop
            end
            forward :interrupt => :failed

            event :runtime_error
            forward :runtime_error => :failed

            event :fatal_error
            forward :fatal_error => :failed

            ##
            # :method: stop!
            #
            # Interrupts the execution of this task context
            event :stop do
                interrupt!
            end

            def self.driver_for(model, arguments = Hash.new)
                if model.respond_to?(:to_str)
                    begin
                        model = Orocos::RobyPlugin::DeviceDrivers.const_get model.to_str.camelcase(true)
                    rescue NameError
                        device_arguments, arguments = Kernel.filter_options arguments,
                            :provides => nil

                        if !device_arguments[:provides]
                            # Look for an existing data source that match the name.
                            # If there is none, we will assume that +self+ describes
                            # the interface of +model+
                            if !system.has_interface?(model)
                                device_arguments[:interface] = self
                            end
                        end
                        model = system.device_type model, device_arguments
                    end
                end
                if !(model < DeviceDriver)
                    raise ArgumentError, "#{model} is not a device driver model"
                end
                data_source_name, _ = data_source(model, arguments)
                argument "#{data_source_name}_name"
            end

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def self.define_from_orogen(task_spec, system = nil)
                superclass = task_spec.superclass
                if !(supermodel = Roby.app.orocos_tasks[superclass.name])
                    supermodel = define_from_orogen(superclass, system)
                end

                klass = Class.new(supermodel)
                klass.instance_variable_set :@orogen_spec, task_spec
                namespace = Orocos::RobyPlugin.orogen_project_module(task_spec.component.name)
                klass.instance_variable_set :@name, "#{task_spec.component.name.camelcase(true)}::#{task_spec.basename.camelcase(true)}"
                klass.instance_variable_set :@system, system
                namespace.const_set(task_spec.basename.camelcase(true), klass)
                
                # Define specific events for the extended states (if there is any)
                if task_spec.extended_state_support?
                    state_events = { :FATAL_ERROR => :fatal_error, :RUNTIME_ERROR => :runtime_error }
                    task_spec.states.each do |name, type|
                        event_name = name.snakecase.downcase
                        klass.event event_name
                        if type == :error || type == :fatal
                            klass.forward event_name => :failed
                        end

                        state_events[name.to_sym] = event_name
                    end

                    klass.instance_variable_set :@state_events, state_events
                end

                klass
            end
        end
    end
end

