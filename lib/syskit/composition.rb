# frozen_string_literal: true

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

        argument :conf, default: []

        # See Models::Composition#strict_specialization_selection?
        @strict_specialization_selection = true

        terminates

        def initialize(**)
            @child_selection = {}
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
                raise ArgumentError, "unlike with ConfigurationManager, only one "\
                                        "configuration can be selected on compositions"
            end

            result = {}
            found_something = false
            model.each_configuration(names.first.to_s, false) do |values|
                found_something = true
                result = values.merge(result)
            end

            unless found_something
                if names == ["default"]
                    ConfigurationManager.info \
                        "required default configuration on composition #{task}, "\
                        "but #{task.model.short_name} has no registered "\
                        "default configurations"
                    return {}
                else
                    raise ArgumentError, "#{self} has no declared configuration "\
                                            "called #{names.join(', ')}"
                end
            end
            result
        end

        # (see Component#post_instanciation_setup)
        def post_instanciation_setup(**arguments)
            super
            return unless (conf_names = arguments[:conf])

            conf(conf_names).each do |child_name, selected_conf|
                child_task = child_from_role(child_name)
                child_task.post_instanciation_setup(conf: selected_conf)
            end
        end

        def resolve_port(port_name)
            export = model.find_exported_input(port_name) ||
                     model.find_exported_output(port_name)
            child_name = export.component_model.child_name
            return unless (child = find_child_from_role(child_name))

            actual_port_name = child_selection[child_name].port_mappings[export.name]
            if child.respond_to?(:resolve_port)
                child.resolve_port(actual_port_name)
            else child.find_port(actual_port_name)
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

        def update_requirements(new_requirements, name: nil, keep_abstract: false)
            super
            new_requirements.dynamics.ports.each do |port_name, info|
                find_port(port_name).to_actual_port.component
                                    .requirements.dynamics.add_port_info(port_name, info)
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
        def find_required_composition_child_from_role(role, from_model = model)
            return unless (selected = child_selection[role])
            # Check what the child is made of ... We might not have to
            # return a service
            return unless (task = find_child_from_role(role))

            target_child_model = from_model.find_child(role)
            unless (target_srv = target_child_model.service)
                return task
            end

            service_selections = [selected.service_selection]
            child_model = model.find_child(role)
            until from_model.fullfills?(child_model.composition_model)
                service_selections.unshift child_model.overload_info.service_selection
                child_model = child_model.parent_model
            end
            selected_service_m = service_selections.inject(target_srv) do |srv, selections|
                break srv unless (selected_srv = selections[srv.model])

                if task.model <= selected_srv.component_model
                    selected_srv
                else selected_srv.as_real_model
                end
            end
            selected_service_m.bind(task).as(target_srv.model)
        end

        # (see find_required_composition_child_from_role)
        #
        # @return [Component,BoundDataService]
        # @raise ArgumentError if the requested child does not exist
        def required_composition_child_from_role(role)
            selected = find_required_composition_child_from_role(role)
            unless selected
                raise ArgumentError, "#{role} does not seem to be a proper child "\
                                     "of this composition"
            end
            selected
        end

        # Overriden from Roby::Task
        #
        # will return false if any of the children is not executable.
        def executable? # :nodoc:
            return false unless super
            return true if @executable

            each_child do |child_task, _|
                if child_task.kind_of?(TaskContext)
                    return false unless child_task.orocos_task
                elsif child_task.kind_of?(Component) && child_task.start_event.root?
                    return false unless child_task.executable?
                end
            end
            true
        end

        # @api private
        #
        # Helper for #added_child_object and #removing_child_object
        #
        # It adds the task to {Flows::DataFlow#modified_tasks} whenever the
        # DataFlow relations is changed in a way that could require changing
        # the underlying Orocos components connections.
        def dataflow_change_handler(ignore_missing_child, _child, mappings) # :nodoc:
            # The case where 'child' is already a task context is already
            # taken care of by
            mappings.each_key do |source_port, _sink_port|
                component =
                    begin find_port(source_port).to_actual_port.component
                    rescue Roby::NoSuchChild
                        raise unless ignore_missing_child
                    end

                if component
                    relation_graph_for(Flows::DataFlow).modified_tasks << component
                end
            end
        end

        # Hook called when one of the compositions' child has been removed
        #
        # If self has exported ports, this broke some connections (the
        # exported ports are not "internally connected" anymore) and as such
        # the corresponding tasks should be added to modified_tasks
        def removing_child(child)
            super
            dataflow_graph = relation_graph_for(Flows::DataFlow)
            if dataflow_graph.has_edge?(child, self)
                # output ports, we only need to make sure that the dataflow
                # handlers are called
                dataflow_graph.remove_relation(child, self)
            end

            return unless dataflow_graph.has_edge?(self, child)

            # This one is harder, we need to explicitely add the sources
            # because none of the other triggers will work
            #
            # Note that merging and dependency injection can cause a child
            # to have a non-forwarding connection to the composition. We
            # can't assume that the edges from self to child are all forwarding
            # (input-to-input)
            dataflow_graph.edge_info(self, child)
                          .each_key do |self_port_name, _child_port_name|
                if (self_port = find_input_port(self_port_name))
                    self_port.each_concrete_connection do |source_port|
                        dataflow_graph.modified_tasks << source_port.component
                    end
                end
            end
        end

        # Called when a new child is added to this composition.
        #
        # It updates {Flows::DataFlow#modified_tasks} so that the engine can
        # update the underlying task's connections
        def added_sink(child, mappings) # :nodoc:
            super
            dataflow_change_handler(false, child, mappings)
        end

        def updated_sink(child, mappings)
            super
            dataflow_change_handler(false, child, mappings)
        end

        # Called when a child is removed from this composition.
        #
        # It updates {Flows::DataFlow#modified_tasks} so that the engine can
        # update the underlying task's connections
        def removing_sink(child) # :nodoc:
            super
            dataflow_change_handler(true, child, self[child, Flows::DataFlow])
        end

        # Generates the InstanceRequirements object that represents +self+
        # best
        #
        # @return [Syskit::InstanceRequirements]
        def to_instance_requirements
            req = super
            use_flags = {}
            model.each_child do |child_name, _|
                use_flags[child_name] = required_composition_child_from_role(child_name)
                                        .to_instance_requirements
            end
            req.use(use_flags)
            req
        end

        # Proxy returned by the child_name_child handler
        #
        # This is used to perform port mapping if needed
        class CompositionChildInstance
            def initialize(composition_task, child_name, child_task)
                @composition_task = composition_task
                @child_name = child_name
                @child_task = child_task
            end

            def as_plan
                @child_task
            end

            def connect_ports(target_task, mappings)
                mapped_connections = {}
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

            def respond_to_missing?(m, include_private)
                (m =~ /_port$/) || super
            end

            # rubocop:disable Style/MethodMissingSuper
            def method_missing(m, *args, &block)
                unless (matched_port = /_port$/.match(m))
                    return @child_task.send(m, *args, &block)
                end

                port_name = matched_port.pre_match
                mapped_port_name = @composition_task
                                   .map_child_port(@child_name, port_name)
                port = @child_task.find_input_port(mapped_port_name) ||
                       @child_task.find_output_port(mapped_port_name)

                unless port
                    raise NoMethodError, "task #{@child_task}, child #{@child_name} "\
                                            "of #{@composition_task}, has no port "\
                                            "called #{port_name}"
                end
                port
            end
            # rubocop:enable Style/MethodMissingSuper
        end
    end
end
