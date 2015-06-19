module Syskit
        # Compositions, i.e. grouping of components and/or other compositions
        # that perform a given function.
        #
        # Compositions are used to regroup components and/or other compositions
        # in functional groups.
        #
        # See the Models::Composition for class-level methods
        class Composition < Component
            extend Models::Composition
            include Syskit::PortAccess

            abstract

            # See Models::Composition#strict_specialization_selection?
            @strict_specialization_selection = true

            terminates

            def initialize(options = Hash.new)
                @child_selection = Hash.new
                super
            end

            # A name => SelectedChild mapping of the selection result during
            # #instanciate
            attr_reader :child_selection

            # Returns the configuration definition for the given
            # configuration(s)
            #
            # Note that unlike ConfigurationManager, only one configuration
            # can be selected (they cannot be overlaid on top of each other)
            #
            # The returned value is a mapping from child names to the
            # configurations that should be applied to them, i.e. for the
            # 'narrow' configuration used as an example in Composition.conf,
            #
            #   conf(['narrow'])
            #
            # would return
            #
            #   'monitoring' => ['default', 'narrow_window'],
            #   'sonar' => ['default', 'narrow_window']
            def conf(names)
                if names.size != 1
                    raise ArgumentError, "unlike with ConfigurationManager, only one  configuration can be selected on compositions"
                end

                result = Hash.new
                found_something = false
                model.each_configuration(names.first.to_s, false) do |values|
                    found_something = true
                    result = values.merge(result)
                end
                if !found_something
                    if names == ['default']
                        ConfigurationManager.info "required default configuration on composition #{task}, but #{task.model.short_name} has no registered default configurations"
                        return result
                    else
                        raise ArgumentError, "#{self} has no declared configuration called #{names.join(", ")}"
                    end
                end
                result
            end

            def resolve_port(port_name)
                export = model.find_exported_input(port_name) ||
                    model.find_exported_output(port_name)
                child_name = export.component_model.child_name
                if child = find_child_from_role(child_name)
                    actual_port_name = child_selection[child_name].port_mappings[export.name]
                    if child.respond_to?(:resolve_port)
                        child.resolve_port(actual_port_name)
                    else child.find_port(actual_port_name)
                    end
                end
            end

            # Maps a port exported on this composition to the port
            # that it represents on the actual task context
            #
            # @param [Syskit::Port] exported_port the port to be mapped
            # @return [Syskit::Port] the actual port. Its {Port#component}
	    #   attribute is guaranteed to be an instance of TaskContext
            def self_port_to_actual_port(exported_port)
                port_name = exported_port.name

                export = model.find_exported_input(port_name) ||
                    model.find_exported_output(port_name)

                child_name = export.component_model.child_name
                child = child_from_role(child_name)
                actual_port_name = child_selection[child_name].port_mappings[export.name]
                child.find_port(actual_port_name).to_actual_port
            end

            # Maps a port exported on this composition to the actual orocos port
            # that it represents
            #
            # @param [Syskit::Port] exported_port the port to be mapped
            # @return [Orocos::Port] the actual port
            def self_port_to_orocos_port(exported_port)
		self_port_to_actual_port(exported_port).to_orocos_port
            end
            

            # Finds the corresponding syskit port
            # @param [String] the name of the port that should be found
            # @return [Syskit::Port] the actuar orocos port with the given name
            # @raises [ArgumentError] if the port does not exist
            def port_by_name(name)
                if p = find_input_port(name) || find_output_port(name) 
                    p
                else raise ArgumentError, "#{self} has no port called #{name}, known ports are: #{each_port.map(&:name).sort.join(", ")}"
                end
            end

            # Returns a child from its role, as the composition model tells we
            # should see it
            #
            # Generally speaking, if the composition model requires a data
            # service, this service is going to be returned instead of the
            # whole task
            #
            # @return [Component,BoundDataService,nil]
            def find_required_composition_child_from_role(role, from_model = self.model)
                selected = child_selection[role]
                return if !selected
                # Check what the child is made of ... We might not have to
                # return a service
                task = find_child_from_role(role)
                return if !task

                target_child_model = from_model.find_child(role)
                if target_srv = target_child_model.service
                    service_selections = [selected.service_selection]
                    child_model = self.model.find_child(role)
                    while !from_model.fullfills?(child_model.composition_model)
                        service_selections.unshift child_model.overload_info.service_selection
                        child_model = child_model.parent_model
                    end
                    selected_service_m = service_selections.inject(target_srv.model) do |srv, selections|
                        if selected_srv = selections[srv]
                            if task.model <= selected_srv.component_model
                                selected_srv
                            else selected_srv.as_real_model.model
                            end
                        else break srv
                        end
                    end
                    return selected_service_m.bind(task).as(target_srv.model)
                else return task
                end
            end

            # (see find_required_composition_child_from_role)
            #
            # @return [Component,BoundDataService]
            # @raise ArgumentError if the requested child does not exist
            def required_composition_child_from_role(role)
                selected = find_required_composition_child_from_role(role)
                if !selected
                    raise ArgumentError, "#{role} does not seem to be a proper child of this composition"
                end
                selected
            end

            # Overriden from Roby::Task
            #
            # will return false if any of the children is not executable.
            def executable? # :nodoc:
                if !super
                    return false
                elsif @executable
                    return true
                end

                each_child do |child_task, _|
                    if child_task.kind_of?(TaskContext)
                        if !child_task.orocos_task
                            return false
                        end
                    elsif child_task.kind_of?(Component) && child_task.start_event.root?
                        if !child_task.executable?
                            return false
                        end
                    end
                end
                return true
            end

            # Helper for #added_child_object and #removing_child_object
            #
            # It adds the task to Flows::DataFlow.modified_tasks whenever the
            # DataFlow relations is changed in a way that could require changing
            # the underlying Orocos components connections.
            def dataflow_change_handler(child, mappings) # :nodoc:
                return if !plan || !plan.real_plan.executable?

                if child.kind_of?(TaskContext)
                    Flows::DataFlow.modified_tasks << child
                else
                    mappings ||= self[child, Flows::DataFlow]
                    mappings.each_key do |source_port, sink_port|
                        if real_port = resolve_port(source_port)
                            real_task = real_port.component
                            if real_task && !real_task.transaction_proxy? # can be nil if the child has been removed
                                Flows::DataFlow.modified_tasks << real_task
                            end
                        end
                    end
                end
            end

            # Called when a new child is added to this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def added_child_object(child, relations, mappings) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, mappings)
                end
            end

            # Called when a child is removed from this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def removing_child_object(child, relations) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, nil)
                end
            end

            # Generates the InstanceRequirements object that represents +self+
            # best
            #
            # @return [Syskit::InstanceRequirements]
            def to_instance_requirements
                req = super
                use_flags = Hash.new
                model.each_child do |child_name, _|
                    use_flags[child_name] = required_composition_child_from_role(child_name).to_instance_requirements
                end
                req.use(use_flags)
                req
            end

            # Proxy returned by the child_name_child handler
            #
            # This is used to perform port mapping if needed
            class CompositionChildInstance
                def initialize(composition_task, child_name, child_task)
                    @composition_task, @child_name, @child_task = composition_task, child_name, child_task
                end
                def as_plan
                    @child_task
                end

                def connect_ports(target_task, mappings)
                    mapped_connections = Hash.new
                    mappings.map do |(source, sink), policy|
                        source = find_output_port(source).name
                        mapped_connections[[source, sink]] = policy
                    end
                    @child_task.connect_ports(target_task, mapped_connections)
                end

                def disconnect_ports(target_task, mappings)
                    mappings = mappings.map do |source, sink|
                        source = find_output_port(source).name
                        [source, sink]
                    end
                    @child_task.disconnect_ports(target_task, mappings)
                end

                def method_missing(m, *args, &block)
                    if m.to_s =~ /^(\w+)_port$/
                        port_name = $1
                        mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                        if port = @child_task.find_input_port(mapped_port_name)
                            return port
                        elsif port = @child_task.find_output_port(mapped_port_name)
                            return port
                        else raise NoMethodError, "task #{@child_task}, child #{@child_name} of #{@composition_task}, has no port called #{port_name}"
                        end
                    end
                    @child_task.send(m, *args, &block)
                end
            end
        end
end

