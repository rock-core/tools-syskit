module Syskit
        # Base class for models that represent components (TaskContext,
        # Composition)
        #
        # The model-level methods (a.k.a. singleton methods) are defined on
        # Models::Component). See the documentation of Model for an explanation of
        # this.
        #
        # Components may be data service providers. Two types of data sources
        # exist:
        # * main services are root data services that can be provided
        #   independently
        # * slave sources are data services that depend on another service. For
        #   instance, an ImageProvider source of a StereoCamera task could be
        #   slave of the main PointCloudProvider source.
        #
        # Data services are referred to by name. In the case of a main service,
        # its name is the name used during the declaration. In the case of slave
        # services, it is main_data_service_name.slave_name. I.e. the name of
        # the slave service depends on the selected 
        class Component < ::Roby::Task
            extend Models::Component
            include Syskit::PortAccess

            abstract

            # See Models::Base#permanent_model?
            @permanent_model = true

            # The name of the process server that should run this component
            #
            # On regular task contexts, it is the host on which the task is
            # required to run. On compositions, it affects the composition's
            # children
            attr_accessor :required_host

            # The InstanceRequirements object for which this component has been
            # instanciated.
            attr_reader :requirements

            # Returns the Robot::RobotDefinition that describes the robot we are
            # running on
            #
            # It returns a valid value only on tasks that are currently included
            # in a plan
            #
            # @return [Robot::RobotDefinition]
            def robot
                return if !plan
                plan.real_plan.orocos_engine.robot
            end

            def initialize(options = Hash.new)
                super
                @reusable = true
                @requirements = InstanceRequirements.new
            end

            def create_fresh_copy
                new_task = super
                new_task.robot = robot
                new_task
            end

            def reusable?
                super && @reusable
            end

            def do_not_reuse
                @reusable = false
            end

            # Returns a set of hints that should be used to disambiguate the
            # deployment of this task.
            #
            # It looks for #deployment_hints in the requirements. If there are
            # none, it then looks in the parents.
            def deployment_hints
                hints = requirements.deployment_hints
                return hints if !hints.empty?

                result = Set.new
                each_parent_task do |p|
                    result |= p.deployment_hints
                end
                result
            end

            # Returns the set of models this task fullfills
            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            # Return the device instance name that is tied to the given provided
            # data service
            #
            # +data_service+ is a Models::BoundDataService, i.e. a value
            # returned by e.g. Component.find_data_service, or the name of a
            # service declared on this component. This service should be a
            # device model. The value returned by this function is then the
            # name of the robot's device which is tied to this service
            def selected_device(data_service)
                if data_service.respond_to?(:to_str)
                    data_service = model.find_data_service(data_service)
                end

                if data_service.master
                    parent_service_name = selected_device(data_service.master)
                    "#{parent_service_name}.#{data_service.name}"
                else
                    arguments["#{data_service.name}_name"]
                end
            end

            # Finds a data service by its name
            #
            # @param [String] the data service name
            # @return [BoundDataService,nil] the found data service, or nil if
            #   there are no services with that name in self
            def find_data_service(service_name)
                if service_model = model.find_data_service(service_name)
                    return service_model.bind(self)
                end
            end

            # Finds a data service by its data service model
            #
            # @param [Model<DataService>] the data service model we want to find
            #   in self
            # @return [BoundDataService,nil] the found data service, or nil if there
            #   are no services of that type in self
            # @raise (see Models::DataService#find_data_service_from_type)
	    def find_data_service_from_type(service_type)
                if service_model = model.find_data_service_from_type(service_type)
                    return service_model.bind(self)
                end
	    end

            # Returns true if the underlying Orocos task is in a state that
            # allows it to be configured
            def ready_for_setup? # :nodoc:
                true
            end

            # Returns true if the underlying Orocos task has been properly
            # configured
            attr_predicate :setup?, true

            # Call to configure the component. User-provided configuration calls
            # should be defined in a #configure method
            #
            # Note that for error-handling reasons, the setup? flag is not set
            # by this method. Caller must call is_setup! after a successful call
            # to #setup
            def setup
                configure
            end

            # User-provided part of the component configuration
            def configure
                super if defined? super
            end

            def user_required_model
                if model.respond_to?(:proxied_data_services)
                    model.proxied_data_services
                else
                    [model]
                end
            end

            def can_merge?(target_task)
                if !(super_result = super)
                    NetworkGeneration.debug { "cannot merge #{target_task} into #{self}: super returned false" }
                    return super_result
                end

                # The orocos bindings are a special case: if +target_task+ is
                # abstract, it means that it is a proxy task for data
                # source/device drivers model
                #
                # In that particular case, the only thing the automatic merging
                # can do is replace +target_task+ iff +self+ fullfills all tags
                # that target_task has (without considering target_task itself).
                target_models = target_task.model.each_fullfilled_model
                if !fullfills?(target_models)
                    NetworkGeneration.debug { "cannot merge #{target_task} into #{self}: #{self} does not fullfill the required model #{target_models.map(&:name).join(", ")}" }
                    return false
                end

                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                self_inputs = Hash.new { |h, k| h[k] = Hash.new }
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    self_inputs[sink_port][[source_task, source_port]] = policy
                end

                might_be_cycle = false
                target_task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if (port_model = model.find_input_port(sink_port)) && port_model.multiplexes?
                        next
                    end

                    # If +self+ has no connection on +sink_port+, it is valid
                    if !self_inputs.has_key?(sink_port)
                        next
                    end

                    # If the exact same connection is provided, verify that
                    # the policies match
                    if conn_policy = self_inputs[sink_port][[source_task, source_port]]
                        if !policy.empty? && (Syskit.update_connection_policy(conn_policy, policy) != policy)
                            NetworkGeneration.debug { "cannot merge #{target_task} into #{self}: incompatible policies on #{sink_port}" }
                            return false
                        end
                        next
                    end

                    # Otherwise, we look for potential cycles, i.e. for
                    # connections where:
                    #
                    #  * the port names are the same
                    #  * the tasks are different
                    #  * but the tasks are interlinked
                    #
                    # If there seem to be a cycle, return a "maybe".
                    # Otherwise, return false
                    found = false
                    self_inputs[sink_port].each do |conn, conn_policy|
                        next if conn[1] != source_port

                        if Flows::DataFlow.reachable?(self, conn[0]) && Flows::DataFlow.reachable?(target_task, source_task)
                            if Syskit.update_connection_policy(conn_policy, policy) == policy
                                found = true
                            end
                        end
                    end

                    if found
                        might_be_cycle = true
                    else
                        NetworkGeneration.debug do
                            NetworkGeneration.debug "cannot merge #{target_task} into #{self}: incompatible connections on #{sink_port}, resp."
                            NetworkGeneration.debug "    #{source_task}.#{source_port}"
                            NetworkGeneration.debug "    --"
                            self_inputs[sink_port].each_key do |conn|
                                NetworkGeneration.debug "    #{conn[0]}.#{conn[1]}"
                            end
                            break
                        end
                        return false
                    end
                end

                if might_be_cycle
                    return nil # undecided
                else
                    return true
                end
            end

            def merge(merged_task)
                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each_static do |key, value|
                    arguments[key] = value if !arguments.set?(key)
                end

                # Merge the fullfilled model if set explicitely
                explicit_merged_fullfilled_model = merged_task.instance_variable_get(:@fullfilled_model)
                explicit_this_fullfilled_model = @fullfilled_model
                if explicit_this_fullfilled_model && explicit_merged_fullfilled_model
                    self.fullfilled_model = Roby::TaskStructure::Dependency.merge_fullfilled_model(
                        explicit_merged_fullfilled_model,
                        [explicit_this_fullfilled_model[0]] + explicit_this_fullfilled_model[1],
                        explicit_this_fullfilled_model[2])

                elsif explicit_merged_fullfilled_model
                    self.fullfilled_model = explicit_merged_fullfilled_model.dup
                end

                # Merge the InstanceRequirements objects
                requirements.merge(merged_task.requirements)

                # Call included plugins if there are some
                super if defined? super

                # Finally, remove +merged_task+ from the data flow graph and use
                # #replace_task to replace it completely
                plan.replace_task(merged_task, self)
                nil
            end

            # The set of data readers created with #data_reader. Used to disconnect
            # them when the task stops
            attribute(:data_readers) { Array.new }

            # The set of data writers created with #data_writer. Used to disconnect
            # them when the task stops
            attribute(:data_writers) { Array.new }

            # Common implementation of port search for #data_reader and
            # #data_writer
            def data_accessor(*args) # :nodoc:
                policy = Hash.new
                if args.last.respond_to?(:to_hash)
                    policy = args.pop
                end

                port_name = args.pop
                if !args.empty?
                    role_path = args
                    parent = resolve_role_path(role_path[0..-2])
                    task   = parent.child_from_role(role_path.last)
                    if parent.respond_to?(:map_child_port)
                        port_name = parent.map_child_port(role_path.last, port_name)
                    end
                else
                    task = self
                end

                return task, port_name, policy
            end

            # call-seq:
            #   data_writer 'port_name'[, policy]
            #   data_writer 'role_name', 'port_name'[, policy]
            #
            # Returns a data writer that allows to read the specified port
            #
            # In the first case, the returned writer is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_writer('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The writer is automatically disconnected when the task quits
            def data_writer(*args)
                task, port_name, policy = data_accessor(*args)

                port = task.find_input_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no input port #{port_name}"
                end

                result = port.writer(policy)
                data_writers << result
                result
            end

            # call-seq:
            #   data_reader 'port_name'[, policy]
            #   data_reader 'role_name', 'port_name'[, policy]
            #
            # Returns a data reader that allows to read the specified port
            #
            # In the first case, the returned reader is applied to a port on +self+.
            # In the second case, it is a port of the specified child. In both
            # cases, an optional connection policy can be specified as
            #
            #   data_reader('pose', 'pose_samples', :type => :buffer, :size => 1)
            #
            # A pull policy is taken by default, as to avoid impacting the
            # components.
            #
            # The reader is automatically disconnected when the task quits
            def data_reader(*args)
                task, port_name, policy = data_accessor(*args)
                policy, other_policy = Kernel.filter_options policy, :pull => true
                policy.merge!(other_policy)

                port = task.find_output_port(port_name)
                if !port
                    raise ArgumentError, "#{task} has no output port #{port_name}"
                end

                result = port.reader(policy)
                data_readers << result
                result
            end

            on :stop do |event|
                data_writers.each do |writer|
                    if writer.connected?
                        writer.disconnect
                    end
                end
                data_readers.each do |reader|
                    if reader.connected?
                        reader.disconnect
                    end
                end
            end

            def to_component; self end

            def method_missing(m, *args)
                return super if !args.empty? || block_given?

                if m.to_s =~ /^(\w+)_port$/
                    port_name = $1
                    if port = find_input_port(port_name)
                        return port
                    elsif port = find_output_port(port_name)
                        return port
                    else
                        raise NoMethodError, "#{self} has no port called #{port_name}"
                    end
                elsif m.to_s =~ /^(\w+)_srv$/
                    service_name = $1
                    if service_model = find_data_service(service_name)
                        return service_model
                    else
                        raise NoMethodError, "#{self} has no service called #{service_name}"
                    end
                end
                super
            end

            # Returns a view of this component as a provider of the given
            # service model. It can for instance be used to connect ports while
            # transparently applying port mappings
            #
            # It works only if there is only one service providing the requested
            # type on +self+. Otherwise, one will have to select the service
            # first and only then call #as on the DataServiceInstance object
            #
            # The same can be done at the model level with Models::Component#as
            def as(service_model)
                return model.as(service_model).bind(self)
            end

            # Resolves the given Syskit::Port object into a Port object where
            # #component is guaranteed to be a proper component instance
            #
            # It should not be used directly. One should usually use
            # Port#to_component_port
            #
            # @param [Syskit::Port]
            # @return [Syskit::Port] a port in which Port#component is
            #   guaranteed to be a proper component (e.g. not BoundDataService)
            def self_port_to_component_port(port)
                model.self_port_to_component_port(port.model).bind(self)
            end

            # Resolves the given Syskit::Port object into the actual Port object
            # on the underlying task.
            #
            # It should not be used directly. One should usually use
            # Port#to_orocos_port instead
            #
            # @return [Orocos::Port]
            def self_port_to_orocos_port(port)
                orocos_task.find_port(port.type, port.name)
            end

            # Automatically computes connections from the output ports of self
            # to the given port or to the input ports of the given component
            #
            # (see Syskit.connect)
            def connect_to(port_or_component)
                Syskit.connect(self, port_or_component)
            end

            def bind(task)
                if !task.kind_of?(self)
                    raise TypeError, "cannot bind #{self} to #{task}"
                end
                task
            end

            # Requires a new dynamic service on this task context
            #
            # As {Models::Component#dynamic_service} already stated, the new
            # dynamic service is a description of what the task should provide.
            # One needs to reimplement the model's #configure method to actually
            # configure the task properly.
            #
            # @return [BoundDataService] the newly created service
            def require_dynamic_service(dynamic_service_name, options = Hash.new)
                options, dyn_options = Kernel.filter_options options,
                    :as => nil
                if !options[:as]
                    raise ArgumentError, "no name given, please provide the :as option"
                end
                service_name = options[:as]

                specialize
                dyn = model.find_dynamic_service(dynamic_service_name)
                if !dyn
                    raise ArgumentError, "#{model.name} has no dynamic service called #{dynamic_service_name}, available dynamic services are: #{model.each_dynamic_service.map(&:name).sort.join(", ")}"
                end

                if srv = find_data_service(service_name)
                    if srv.fullfills?(dyn.service_model)
                        return srv
                    else raise ArgumentError, "there is already a service #{service_name}, but it is of type #{srv.model.short_name} while the dynamic service #{dynamic_service_name} expects #{dyn.service_model.short_name}"
                    end
                end
                bound_service = dyn.instanciate(service_name, dyn_options)

                needs_reconfiguration!
                bound_service.bind(self)
            end

            # Sets up this task to use its singleton class as model instead of
            # the plain class. It is useful in particular for dynamic services
            def specialize
                if model != singleton_class
                    @model = singleton_class
                    model.name = self.class.name
                    model.private_specialization = true
                    model.private_model
                    model.setup_submodel
                    true
                end
            end

            module Proxying
                proxy_for Component

                def setup_proxy(object, plan)
                    super
                    @do_not_reuse = object.instance_variable_get :@do_not_reuse
                end

                def commit_transaction
                    super
                    if @do_not_reuse
                        __getobj__.do_not_reuse
                    end
                end
            end
        end
end

