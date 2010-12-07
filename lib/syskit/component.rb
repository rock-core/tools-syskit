module Orocos
    module RobyPlugin
        # Data structure used internally to represent the data services that are
        # provided by a given component
        class ProvidedDataService
            # The task model which provides this service
            attr_reader :component_model
            # The service name
            attr_reader :name
            # The master service (if there is one)
            attr_reader :master
            # The service model
            attr_reader :model
            # The mappings needed between the ports in the service interface and
            # the actual ports on the component
            attr_reader :port_mappings

            # The service's full name, i.e. the name with which it is referred
            # to in the task model
            attr_reader :full_name

            # :attr: main?
            #
            # True if this service is a main service. See
            # ComponentModel.data_service for more information
            attr_predicate :main, true
            # True if this service is not a slave service
            def master?; !@master end

            def initialize(name, component_model, master, model, port_mappings)
                @name, @component_model, @master, @model, @port_mappings = 
                    name, component_model, master, model, port_mappings

                @full_name =
                    if master
                        "#{master.name}.#{name}"
                    else
                        name
                    end
            end

            def config_type
                model.config_type
            end

            def has_output_port?(name)
                each_output_port.find { |p| p.name == name }
            end

            def has_input_port?(name)
                each_input_port.find { |p| p.name == name }
            end

            # Yields the port models for this service's input, applied on the
            # underlying task. I.e. applies the port mappings to the service
            # definition
            def each_input_port
                if block_given?
                    port_mappings = port_mappings_for(model)
                    model.each_input_port do |input_port|
                        port_name = input_port.name
                        if mapped_port = port_mappings[port_name]
                            port_name = mapped_port
                        end
                        p = component_model.find_input_port(port_name)
                        if !p
                            raise InternalError, "#{component_model.short_name} was expected to have a port called #{port_name} to fullfill #{model.short_name}. Port mappings are #{port_mappings}"
                        end
                        yield(p)
                    end
                else
                    enum_for(:each_input_port)
                end
            end

            # Yields the port models for this service's output, applied on the
            # underlying task. I.e. applies the port mappings to the service
            # definition
            def each_output_port
                if block_given?
                    port_mappings = port_mappings_for(model)
                    model.each_output_port do |output_port|
                        port_name = output_port.name
                        if mapped_port = port_mappings[port_name]
                            port_name = mapped_port
                        end
                        p = component_model.find_output_port(port_name)
                        if !p
                            raise InternalError, "#{component_model.short_name} was expected to have a port called #{port_name} to fullfill #{model.short_name}. Port mappings are #{port_mappings}"
                        end
                        yield(p)
                    end
                else
                    enum_for(:each_output_port)
                end
            end

            # If an unknown method is called on this object, try to return the
            # corresponding slave service (if there is one)
            def method_missing(name, *args)
                if subservice = component_model.find_data_service("#{full_name}.#{name}")
                    return subservice
                end
                super
            end
        end

        # Value returned by ComponentModel#as(model). It is used only in the
        # context of model instanciation.
        #
        # It is used to represent that a given model should be narrowed down to
        # a given specific model, and is used during composition instanciation
        # to limit the search scope.
        #
        # For instance, if a task model is defined with
        #
        #   class OrocosTask
        #       provides Service
        #       provides Service1
        #   end
        #
        # then
        #   
        #   add MyComposition, 
        #       "task" => OrocosTask
        #
        # will consider both data services for specialization purposes, whereas
        #
        #   add MyComposition, 
        #       "task" => OrocosTask.as(Service)
        #
        # will only consider specializations that apply on Service instances
        # (i.e. ignore Service1)
        class FacetedModelSelection < BasicObject
            # The underlying model
            attr_reader :model
            # The model that has been selected
            attr_reader :selected_facet

            def respond_to?(name) # :nodoc:
                if name == :selected_facet
                    true
                else
                    super
                end
            end

            def initialize(model, facet)
                @model = model
                @selected_facet = facet
            end

            def to_s
                "#{model}.as(#{selected_facet})"
            end

            def method_missing(*args, &block) # :nodoc:
                model.send(*args, &block)
            end
        end

        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module ComponentModel
            include Model

            ##
            # :method: each_main_data_service
            # :call-seq:
            #   each_main_data_service { |source_name| }
            #
            # Enumerates the name of all the main data sources that are provided
            # by this component model. Unlike #main_data_services, it enumerates
            # both the sources added at this level of the model hierarchy and
            # the ones that are provided by the model's parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ## :attr_reader:main_data_services
            #
            # The names of the main data sources that are provided by this
            # particular component model. This only includes new sources that
            # have been added at this level of the component hierarchy, not the
            # ones that have already been added to the model parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ##
            # :method: each_data_service
            # :call-seq:
            #     each_data_service { |service| }
            #
            # Enumerates all the data sources that are provided by this
            # component model, as pairs of source name and DataService instances.
            # Unlike #data_services, it enumerates both the sources added at
            # this level of the model hierarchy and the ones that are provided
            # by the model's parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ##
            # :method: find_data_service
            # :call-seq:
            #   find_data_service(name) -> service
            #
            # Returns the DataService instance that has the given name, or nil if
            # there is none.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ## :attr_reader: data_services
            #
            # The data sources that are provided by this particular component
            # model, as a hash mapping the source name to the corresponding
            # DataService instance. This only includes new sources that have been
            # added at this level of the component hierarchy, not the ones that
            # have already been added to the model parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            # During instanciation, the data services that this component
            # provides are used to specialize the compositions and/or for data
            # source selection.
            #
            # It is sometimes beneficial to narrow the possible selections,
            # because one wants some specializations to be explicitely selected.
            # This is what this method does.
            #
            # For instance, if a task model is defined with
            #
            #   class OrocosTask
            #       provides Service
            #       provides Service1
            #   end
            #
            # then
            #   
            #   add MyComposition, 
            #       "task" => OrocosTask
            #
            # will consider both data services for specialization purposes, whereas
            #
            #   add MyComposition, 
            #       "task" => OrocosTask.as(Service)
            #
            # will only consider specializations that apply on Service instances
            # (i.e. ignore Service1)
            def as(model)
                FacetedModelSelection.new(self, model)
            end

            # Returns the port object that maps to the given name, or nil if it
            # does not exist.
            def find_port(name)
                name = name.to_str
                find_output_port(name) || find_input_port(name)
            end

            def has_port?(name)
                has_input_port?(name) || has_output_port?(name)
            end

            # Returns the output port with the given name, or nil if it does not
            # exist.
            def find_output_port(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.find_output_port(name)
            end

            # Returns the input port with the given name, or nil if it does not
            # exist.
            def find_input_port(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.find_input_port(name)
            end

            # Enumerates this component's output ports
            def each_output_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_output_port(&block)
            end

            # Enumerates this component's input ports
            def each_input_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_input_port(&block)
            end

            # Enumerates all of this component's ports
            def each_port(&block)
                return [].each(&block) if !respond_to?(:orogen_spec)
                orogen_spec.each_port(&block)
            end

            # Returns true if +name+ is a valid output port name for instances
            # of +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_output_port?(name, including_dynamic = true)
                return true if find_output_port(name)
                if including_dynamic
                    has_dynamic_output_port?(name)
                end
            end

            # Returns true if +name+ is a valid input port name for instances of
            # +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_input_port?(name, including_dynamic = true)
                return true if find_input_port(name)
                if including_dynamic
                    has_dynamic_input_port?(name)
                end
            end

            # True if +name+ could be a dynamic output port name.
            #
            # Dynamic output ports are declared on the task models using the
            # #dynamic_output_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_output_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic output port declarations using this predicate.
            def has_dynamic_output_port?(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.has_dynamic_output_port?(name)
            end

            # True if +name+ could be a dynamic input port name.
            #
            # Dynamic input ports are declared on the task models using the
            # #dynamic_input_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_input_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic input port declarations using this predicate.
            def has_dynamic_input_port?(name)
                return if !respond_to?(:orogen_spec)
                orogen_spec.has_dynamic_input_port?(name)
            end

            # Generic instanciation of a component. 
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the engine's plan and returns it.
            def instanciate(engine, arguments = Hash.new)
                _, task_arguments = Model.filter_instanciation_arguments(arguments)
                engine.plan.add(task = new(task_arguments))
                task.robot = engine.robot
                task
            end
        end

        # Base class for models that represent components (TaskContext,
        # Composition)
        #
        # The model-level methods (a.k.a. singleton methods) are defined on
        # ComponentModel). See the documentation of Model for an explanation of
        # this.
        #
        # Components may be data source providers. Two types of data sources exist:
        # * main sources are root data services that can be provided
        # independently
        # * slave sources are data services that depend on a main one. For
        # instance, an ImageProvider source of a StereoCamera task would be
        # slave of the main PointCloudProvider source.
        #
        # Data services are referred to by name. In the case of a main service,
        # its name is the name used during the declaration. In the case of slave
        # services, it is main_data_service_name.slave_name. I.e. the name of
        # the slave service depends on the selected 
        class Component < ::Roby::Task
            extend ComponentModel

            # The Robot instance we are running on
            attr_accessor :robot

            # Returns the set of communication busses names that this task
            # needs.
            def com_busses
                arguments.find_all do |arg_name, bus_name| 
                    bus_name && (arg_name.to_s =~ /_com_bus$/)
                end.map(&:last).to_set
            end

            def create_fresh_copy
                new_task = super
                new_task.robot = robot
                new_task
            end

            # This is documented on ComponentModel
            inherited_enumerable(:main_data_service, :main_data_services) { Set.new }
            # This is documented on ComponentModel
            inherited_enumerable(:data_service, :data_services, :map => true) { Hash.new }

            attribute(:instanciated_dynamic_outputs) { Hash.new }
            attribute(:instanciated_dynamic_inputs) { Hash.new }

            # Returns the output port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def find_output_port_model(name)
                if port_model = model.orogen_spec.each_output_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_outputs[name]
                end
            end

            def to_short_s
                to_s.gsub /Orocos::RobyPlugin::/, ''
            end

            # Returns the input port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def find_input_port_model(name)
                if port_model = model.orogen_spec.each_input_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_inputs[name]
                end
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_input(name, type = nil)
                if port = instanciated_dynamic_inputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_input_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_inputs[name] = port
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_output(name, type = nil)
                if port = instanciated_dynamic_outputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_output_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_outputs[name] = port
            end

            DATA_SERVICE_ARGUMENTS = { :as => nil, :slave_of => nil, :main => nil, :config_type => nil }

            # Alias for data_service
            def self.provides(*args)
                data_service(*args)
            end

            # Helper method for compute_port_mappings
            def self.compute_directional_port_mappings(result, service, direction, explicit_mappings) # :nodoc:
                remaining = service.model.send("each_#{direction}_port").to_a

                used_ports = service.component_model.
                    send("each_data_service").
                    find_all { |_, task_service| task_service.model == service.model }.
                    map { |_, task_service| task_service.port_mappings.values }.
                    flatten.to_set

                # 0. check if an explicit port mapping is provided for this port
                remaining.delete_if do |port|
                    mapping = explicit_mappings[port.name]
                    next if !mapping

                    # Verify that the mapping is valid
                    component_port = service.component_model.
                        send("find_#{direction}_port", mapping)
                    if !component_port
                        raise InvalidPortMapping, "the explicit mapping from #{port.name} to #{mapping} is invalid as #{mapping} is not an #{direction} port of #{service.component_model.name}"
                    end
                    if component_port.type != port.type
                        raise InvalidPortMapping, "the explicit mapping from #{port.name} to #{mapping} is invalid as they have different types (#{port.type_name} != #{component_port.type_name}"
                    end
                    result[port.name] = mapping
                end

                # 1. check if the task model has a port with the same name
                remaining.delete_if do |port|
                    component_port = service.component_model.
                        send("#{direction}_port", port.name)
                    if component_port && component_port.type == port.type
                        used_ports << component_port.name
                        result[port.name] = port.name
                    end
                end

                while !remaining.empty?
                    current_size = remaining.size
                    remaining.delete_if do |port|
                        # 2. look at all ports that have the same type
                        candidates = service.component_model.send("each_#{direction}_port").
                            find_all { |p| !used_ports.include?(p.name) && p.type == port.type }
                        if candidates.empty?
                            raise InvalidPortMapping, "no candidate to map #{port.name}[#{port.type_name}] from #{service.name} onto #{name}"
                        elsif candidates.size == 1
                            used_ports << candidates.first.name
                            result[port.name] = candidates.first.name
                            next(true)
                        end

                        # 3. try to filter the ambiguity by name
                        name_rx = Regexp.new(service.name)
                        by_name = candidates.find_all { |p| p.name =~ name_rx }
                        if by_name.empty?
                            raise InvalidPortMapping, "#{candidates.map(&:name)} are equally valid candidates to map #{port.name}[#{port.type_name}] from the '#{service.name}' service onto the #{name} task's interface"
                        elsif by_name.size == 1
                            used_ports << by_name.first.name
                            result[port.name] = by_name.first.name
                            next(true)
                        end

                        # 3. try full name if the service is a slave service
                        next if service.master?
                        name_rx = Regexp.new(service.master.name)
                        by_name = by_name.find_all { |p| p.name =~ name_rx }
                        if by_name.size == 1
                            used_ports << by_name.first.name
                            result[port.name] = by_name.first.name
                            next(true)
                        end
                    end

                    if remaining.size == current_size
                        port = remaining.first
                        raise InvalidPortMapping, "there are multiple candidates to map #{port.name}[#{port.type_name}] from #{service.name} onto #{name}"
                    end
                end
            end


            # Compute the port mapping from the interface of 'service' onto the
            # ports of 'self'
            #
            # The returned hash is
            #
            #   service_interface_port_name => task_model_port_name
            #
            def self.compute_port_mappings(service, explicit_mappings)
                normalized_mappings = Hash.new
                explicit_mappings.each do |from, to|
                    from = from.to_s if from.kind_of?(Symbol)
                    to   = to.to_s   if to.kind_of?(Symbol)
                    if from.respond_to?(:to_str) && to.respond_to?(:to_str)
                        normalized_mappings[from] = to 
                    end
                end

                result = Hash.new
                compute_directional_port_mappings(result, service, "input", normalized_mappings)
                compute_directional_port_mappings(result, service, "output", normalized_mappings)
                result
            end

            # Declares that this component provides the given data service.
            # +model+ can either be the data service constant name (from
            # Orocos::RobyPlugin::DataServices), or its plain name.
            #
            # If the data service defines an interface, the component must
            # provide the required input and output ports, *matching the port
            # name*. See the discussion about the 'main' argument for port name
            # matching.
            #
            # The following arguments are accepted:
            #
            # as::
            #   the data service name on this task context. By default, it
            #   will be derived from the model name by converting it to snake
            #   case (i.e. stereo_camera for StereoCamera)
            # slave_of::
            #   creates a data service that is slave from another data service.
            # main::
            #   creates a main data service. For main data services, the
            #   component port names must strictly match the ones defined in the
            #   data service interface. Otherwise, the port names can be
            #   prefixed or postfixed by the data service name. Data services
            #   for which the 'as' argument is not specified are main by
            #   default.
            #
            # +provides+ is an alias for this call
            def self.data_service(model, arguments = Hash.new)
                source_arguments, arguments = Kernel.filter_options arguments,
                    DATA_SERVICE_ARGUMENTS

                if model.respond_to?(:to_str)
                    if system_model.has_data_service?(model.to_str)
                        model = system_model.data_service_model(model.to_str)
                    else
                        raise ArgumentError, "there is no data source type #{model}"
                    end
                end

                if !(model < DataService)
                    raise ArgumentError, "#{model} is not a data source model"
                end

                # If true, the source will be marked as 'main', i.e. the port
                # mapping between the source and the component will match plain
                # port names (without the source name prefixed/postfixed)
                main_data_service = if source_arguments.has_key?(:main)
                                       source_arguments[:main]
                                   else !source_arguments[:as]
                                   end

                # In case no name has been given, check if our parent models
                # already have a source which we could specialize. In that case,
                # reuse their name
                if !source_arguments[:as]
                    if respond_to?(:each_main_data_service)
                        candidates = each_main_data_service.find_all do |source|
                            !data_services[source] &&
                                model <= data_service_type(source)
                        end

                        if candidates.size > 1
                            candidates = candidates.map { |name, _| name }
                            raise Ambiguous, "this definition could overload the following services: #{candidates.join(", ")}. Select one with the :as option"
                        end
                        source_arguments[:as] = candidates.first
                    end
                end

                # Get the source name and the source model
                name = (source_arguments[:as] || model.name.gsub(/^.+::/, '').snakecase).to_str
                if data_services[name]
                    raise ArgumentError, "there is already a source named '#{name}' defined on '#{self.name}'"
                end

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                if has_data_service?(name)
                    parent_type = data_service_type(name)
                    if !(model <= parent_type)
                        raise SpecError, "#{self} has a data source named #{name} of type #{parent_type}, which is not a parent type of #{model}"
                    end
                end

                include model

                if master_source = source_arguments[:slave_of]
                    if !has_data_service?(master_source.to_str)
                        raise SpecError, "master source #{master_source} is not registered on #{self}"
                    end
                    master = find_data_service(master_source)
                end

                service = ProvidedDataService.new(name, self, master, model, Hash.new)
                full_name = service.full_name
                data_services[full_name] = service
                if main_data_service
                    main_data_services << full_name
                    service.main = true
                end
                begin
                    new_port_mappings = compute_port_mappings(service, arguments)
                    service.port_mappings.
                        merge!(new_port_mappings)

                    # Remove from +arguments+ the items that were port mappings
                    new_port_mappings.each do |from, to|
                        if arguments[from].to_s == to # this was a port mapping !
                            arguments.delete(from)
                        elsif arguments[from.to_sym].to_s == to
                            arguments.delete(from.to_sym)
                        end
                    end
                rescue InvalidPortMapping => e
                    raise InvalidProvides.new(e), "#{self.name} does not provide the '#{model.name}' service's interface. #{e.message}", e.backtrace
                end

                arguments.each do |key, value|
                    send("#{key}=", value)
                end
                return service
            end


            # Return the selected name for the given data source, or nil if none
            # is selected yet (or if the service is not a source)
            def selected_data_source(data_service)
                if data_service.respond_to?(:to_str)
                    data_service = model.find_data_service(data_service)
                end

                if data_service.master
                    parent_source_name = selected_data_source(data_service.master)
                    "#{parent_source_name}.#{data_service.name}"
                else
                    arguments["#{data_service.name}_name"]
                end
            end

            # Returns the data service model for the given source name
            #
            # Raises ArgumentError if source_name is not a data source name on
            # this component model.
            def data_service_type(source_name)
                source_name = source_name.to_str
                root_source_name = source_name.gsub /\..*$/, ''
                root_source = model.each_root_data_service.find do |name, source|
                    arguments[:"#{name}_name"] == root_source_name
                end

                if !root_source
                    raise ArgumentError, "there is no source named #{root_source_name}"
                end
                if root_source_name == source_name
                    return root_source.last.model
                end

                subname = source_name.gsub /^#{root_source_name}\./, ''

                model = self.model.data_service_type("#{root_source.first}.#{subname}")
                if !model
                    raise ArgumentError, "#{subname} is not a slave source of #{root_source_name} (#{root_source.first}) in #{self.model.name}"
                end
                model
            end

            def check_is_setup # :nodoc:
                true
            end

            def is_setup?
                @is_setup ||= check_is_setup
            end

            def executable?(with_setup = true)
	    	if forced_executable?
		    return true
                elsif !super()
                    return false
                end

                if with_setup
                    if !is_setup?
                        return false
                    end

                    if pending?
                        return Roby.app.orocos_engine.all_inputs_connected?(self, false)
                    end
                end
                true
            end

            def user_required_model
                if model.respond_to?(:proxied_data_services)
                    model.proxied_data_services.map(&:model)
                else
                    [model]
                end
            end

            def can_merge?(target_task)
                return false if !super

                # The orocos bindings are a special case: if +target_task+ is
                # abstract, it means that it is a proxy task for data
                # source/device drivers model
                #
                # In that particular case, the only thing the automatic merging
                # can do is replace +target_task+ iff +self+ fullfills all tags
                # that target_task has (without considering target_task itself).
                models = user_required_model
                if !fullfills?(models)
                    return false
                end

                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                self_inputs = Hash.new
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if self_inputs.has_key?(sink_port)
                        raise InternalError, "multiple connections to the same input: #{self}:#{sink_port} is connected from #{source_task}:#{source_port} and #{self_inputs[sink_port]}"
                    end
                    self_inputs[sink_port] = [source_task, source_port, policy]
                end
                target_task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if conn = self_inputs[sink_port]
                        same_source = (conn[0] == source_task && conn[1] == source_port)
                        if !same_source
                            return false
                        elsif !policy.empty? && (RobyPlugin.update_connection_policy(conn[2], policy) != policy)
                            return false
                        end
                    end
                end

                true
            end

            def merge(merged_task)
                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each do |key, value|
                    arguments[key] ||= value if !arguments.has_key?(key)
                end

                # Instanciate missing dynamic ports
                self.instanciated_dynamic_outputs =
                    merged_task.instanciated_dynamic_outputs.merge(instanciated_dynamic_outputs)
                self.instanciated_dynamic_inputs =
                    merged_task.instanciated_dynamic_inputs.merge(instanciated_dynamic_inputs)

                # Finally, remove +merged_task+ from the data flow graph and use
                # #replace_task to replace it completely
                plan.replace_task(merged_task, self)
                nil
            end

            def self.method_missing(name, *args)
                if args.empty?
                    if port = self.find_port(name)
                        return port
                    elsif service = self.find_data_service(name.to_s)
                        return service
                    end
                end
                super
            end

            # The set of data readers created with #data_reader. Used to connect
            # them when the task stops
            attribute(:data_readers) { Array.new }

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
                policy = Hash.new
                if args.last.respond_to?(:to_hash)
                    policy = args.pop
                end
                policy, other_policy = Kernel.filter_options policy, :pull => true
                policy.merge!(other_policy)

                port =
                    if args.size == 2
                        role_name, port_name = *args
                        task = child_from_role(role_name)
			if !task
			    raise ArgumentError, "#{self} has no child with role #{role_name}"
			end
			task.output_port(port_name)
                    else
                        port_name = args.first
                        output_port(port_name)
                    end

                result = port.reader(policy)
                data_readers << result
                result
            end
            
            on :stop do |event|
                data_readers.each do |reader|
                    if reader.connected?
                        reader.disconnect
                    end
                end
            end
        end
    end
end

