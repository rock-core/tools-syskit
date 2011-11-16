module Orocos
    module RobyPlugin
        # Represents the actual connection graph between task context proxies.
        # Its vertices are instances of Orocos::TaskContext, and edges are
        # mappings from [source_port_name, sink_port_name] pairs to the
        # connection policy between these ports.
        #
        # Orocos::RobyPlugin::ActualDataFlow is the actual global graph instance
        # in which the overall system connections are maintained in practice
        class ConnectionGraph < BGL::Graph
            # Needed for Roby's marshalling (so that we can dump the connection
            # graph as a constant)
            attr_accessor :name

            # Create new connections between +source_task+ and +sink_task+.
            #
            # +mappings+ is a map from port name pairs to the connection policy
            # that should be used:
            #
            #    [output_port_name, input_port_name] => policy
            #
            # Raises Roby::ModelViolation if the connection already exists with
            # an incompatible policy
            def add_connections(source_task, sink_task, mappings) # :nodoc:
                if mappings.empty?
                    raise ArgumentError, "the connection set is empty"
                end
                if linked?(source_task, sink_task)
                    current_mappings = source_task[sink_task, self]
                    new_mappings = current_mappings.merge(mappings) do |(from, to), old_options, new_options|
                        if old_options.empty? then new_options
                        elsif new_options.empty? then old_options
                        elsif old_options != new_options
                            raise Roby::ModelViolation, "cannot override connection setup with #connect_to (#{old_options} != #{new_options})"
                        end
                        old_options
                    end
                    source_task[sink_task, self] = new_mappings
                else
                    link(source_task, sink_task, mappings)
                end
            end

            # Removes the given set of connections between +source_task+ and
            # +sink_task+.
            #
            # +mappings+ is an array of port name pairs [output_port_name,
            # input_port_name]
            def remove_connections(source_task, sink_task, mappings) # :nodoc:
                current_mappings = source_task[sink_task, self]
                mappings.each do |source_port, sink_port|
                    current_mappings.delete([source_port, sink_port])
                end
                if current_mappings.empty?
                    unlink(source_task, sink_task)
                else
                    # To make the relation system call #update_info
                    source_task[sink_task, self] = current_mappings
                end
            end

            # Tests if +port+, which has to be an output port, is connected
            def has_out_connections?(task, port)
                task.each_child_vertex(self) do |child_task|
                    if task[child_task, self].any? { |source_port, _| source_port == port }
                        return true
                    end
                end
                false
            end

            # Tests if +port+, which has to be an input port, is connected
            def has_in_connections?(task, port)
                task.each_parent_vertex(self) do |parent_task|
                    if parent_task[task, self].any? { |_, target_port| target_port == port }
                        return true
                    end
                end
                false
            end

            # Tests if there is a connection between +source_task+:+source_port+
            # and +sink_task+:+sink_port+
            def connected?(source_task, source_port, sink_task, sink_port)
                if !linked?(source_task, sink_task)
                    return false
                end
                source_task[sink_task, self].has_key?([source_port, sink_port])
            end
        end

        ActualDataFlow   = ConnectionGraph.new
        Orocos::TaskContext.include BGL::Vertex

        def self.update_connection_policy(old, new)
            old = old.dup
            new = new.dup
            if old.empty?
                return new
            elsif new.empty?
                return old
            end

            old_fallback = old.delete(:fallback_policy)
            new_fallback = new.delete(:fallback_policy)
            if old_fallback && new_fallback
                fallback = update_connection_policy(old_fallback, new_fallback)
            else
                fallback = old_fallback || new_fallback
            end

            old = Port.validate_policy(old)
            new = Port.validate_policy(new)

            type = old[:type] || new[:type]
            merged = old.merge(new) do |key, old_value, new_value|
                if old_value == new_value
                    old_value
                elsif key == :type
                    raise ArgumentError, "connection types mismatch: #{old_value} != #{new_value}"
                elsif key == :transport
                    if old_value == 0 then new_value
                    elsif new_value == 0 then old_value
                    else
                        raise ArgumentError, "policy mismatch for transport: #{old_value} != #{new_value}"
                    end
                else
                    raise ArgumentError, "policy mismatch for #{key}: #{old_value} != #{new_value}"
                end
            end

            if fallback
                merged[:fallback_policy] = fallback
            end
            merged
        end

        Flows = Roby::RelationSpace(Component)
        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source, :dag => false, :weak => true do
            # Makes sure that +self+ has an output port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_output_port(name)
                if !model.find_output_port(name)
                    if model.has_dynamic_output_port?(name)
                        instanciate_dynamic_output(name)
                    else
                        raise ArgumentError, "#{self} has no output port called #{name}"
                    end
                end
            end

            # Makes sure that +self+ has an input port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_input_port(name)
                if !model.find_input_port(name)
                    if model.has_dynamic_input_port?(name)
                        instanciate_dynamic_input(name)
                    else
                        raise ArgumentError, "#{self} has no input port called #{name}"
                    end
                end
            end

            def clear_relations
                Flows::DataFlow.remove(self)
                super
            end

            # Forward an input port of a composition to one of its children, or
            # an output port of a composition's child to its parent composition.
            #
            # +mappings+ is a hash of the form
            #
            #   source_port_name => sink_port_name
            #
            # If the +self+ composition is the parent of +target_task+, then
            # source_port_name must be an input port of +self+ and
            # sink_port_name an input port of +target_task+.
            #
            # If +self+ is a child of the +target_task+ composition, then
            # source_port_name must be an output port of +self+ and
            # sink_port_name an output port of +target_task+.
            #
            # Raises ArgumentError if one of the specified ports do not exist,
            # or if +target_task+ and +self+ are not related in the Dependency
            # relation.
            def forward_ports(target_task, mappings)
                if self.child_object?(target_task, Roby::TaskStructure::Dependency)
                    if !fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_input_port(from)
                        target_task.ensure_has_input_port(to)
                    end

                elsif target_task.child_object?(self, Roby::TaskStructure::Dependency)
                    if !target_task.fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_output_port(from)
                        target_task.ensure_has_output_port(to)
                    end
                else
                    raise ArgumentError, "#{target_task} and #{self} are not related in the Dependency relation"
                end

                add_sink(target_task, mappings)
            end

            # Returns true if +port_name+ is connected
            def connected?(port_name)
                each_sink do |sink_task, mappings|
                    if mappings.any? { |(from, to), _| from == port_name }
                        return true
                    end
                end
                each_source do |source_task|
                    mappings = source_task[self, Flows::DataFlow]
                    if mappings.any? { |(from, to), _| from == port_name }
                        return true
                    end
                end
                false
            end

            # Tests if +port_name+ is connected to +other_port+ on +other_task+
            def connected_to?(port_name, other_task, other_port)
                if Flows::DataFlow.linked?(self, other_task)
                    self[other_task, Flows::DataFlow].each_key do |from, to|
                        return true if from == port_name && to == other_port
                    end
                end
                if Flows::DataFlow.linked?(other_task, self)
                    other_task[self, Flows::DataFlow].each_key do |from, to|
                        return true if from == other_port && to == port_name
                    end
                end
                false
            end

            # Connect a set of ports between +self+ and +target_task+.
            #
            # +mappings+ describes the connections. It is a hash of the form
            #   
            #   [source_port_name, sink_port_name] => connection_policy
            #
            # where source_port_name is a port of +self+ and sink_port_name a
            # port of +target_task+
            #
            # Raises ArgumentError if one of the ports do not exist.
            def connect_ports(target_task, mappings)
                if target_task.respond_to?(:as_plan)
                    mapped_connections = Hash.new
                    mappings.map do |(source, sink), policy|
                        sink = target_task.find_input_port(sink).name
                        mapped_connections[[source, sink]] = policy
                    end
                    target_task = target_task.as_plan
                end

                mappings.each do |(out_port, in_port), options|
                    ensure_has_output_port(out_port)
                    target_task.ensure_has_input_port(in_port)
                end

                add_sink(target_task, mappings)
            end

            def disconnect_ports(target_task, mappings)
                if target_task.respond_to?(:as_plan)
                    mappings = mappings.map do |source, sink|
                        sink = target_task.find_input_port(sink)
                        [source, sink.name]
                    end
                    target_task = target_task.as_plan
                end

                if !Flows::DataFlow.linked?(self, target_task)
                    raise ArgumentError, "no such connections #{mappings} for #{self} => #{target_task}"
                end

                connections = self[target_task, Flows::DataFlow]

                result = Hash.new
                mappings.delete_if do |port_pair|
                    result[port_pair] = connections.delete(port_pair)
                end
                if !mappings.empty?
                    raise ArgumentError, "no such connections #{mappings} for #{self} => #{target_task}"
                end
                Flows::DataFlow.modified_tasks << self << target_task
                result
            end

            def disconnect_port(port_name)
                if port_name.respond_to?(:name)
                    port_name = port_name.name
                end

                each_source do |parent_task|
                    current = parent_task[self, Flows::DataFlow]
                    current.delete_if { |(from, to), pol| to == port_name }
                    parent_task[self, Flows::DataFlow] = current
                end
                each_sink do |child_task|
                    current = self[child_task, Flows::DataFlow]
                    current.delete_if { |(from, to), pol| from == port_name }
                    self[child_task, Flows::DataFlow] = current
                end
            end

            # Calls either #connect_ports or #forward_ports, depending on its
            # arguments
            #
            # It calls #forward_ports only if one of [target_task, self] is a
            # composition and the other is part of this composition. Otherwise,
            # calls #connect_ports
            def connect_or_forward_ports(target_task, mappings)
                if kind_of?(Composition) && depends_on?(target_task, false)
                    forward_ports(target_task, mappings)
                elsif target_task.kind_of?(Composition) && target_task.depends_on?(self, false)
                    forward_ports(target_task, mappings)
                else
                    connect_ports(target_task, mappings)
                end
            end

            # call-seq:
            #   sink_task.each_input_connection { |source_task, source_port_name, sink_port_name, policy| ...}
            #
            # Yield or enumerates the connections that exist towards the input
            # ports of +sink_task+. It includes connections to composition ports
            # (i.e. exported ports).
            def each_input_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_input_connection)
                end

                each_source do |source_task|
                    source_task[self, Flows::DataFlow].each do |(source_port, sink_port), policy|
                        if required_port 
                            if sink_port == required_port
                                yield(source_task, source_port, sink_port, policy)
                            end
                        else
                            yield(source_task, source_port, sink_port, policy)
                        end
                    end
                end
            end

            # call-seq:
            #   sink_task.each_input_connection { |source_task, source_port_name, sink_port_name, policy| ...}
            #
            # Yield or enumerates the connections that exist towards the input
            # ports of +sink_task+. It does not include connections to
            # composition ports (i.e. exported ports): these connections are
            # followed until a concrete port (a port on an actual Orocos
            # task context) is found.
            def each_concrete_input_connection(required_port = nil, &block)
                if !block_given?
                    return enum_for(:each_concrete_input_connection, required_port)
                end

                each_input_connection(required_port) do |source_task, source_port, sink_port, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if source_task.kind_of?(Composition)
                        source_task.each_concrete_input_connection(source_port) do |source_task, source_port, _, connection_policy|
                            begin
                                this_policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in input chain for #{self}:#{sink_port}: #{e.message}"
                            end

                            yield(source_task, source_port, sink_port, policy)
                        end
                    else
                        yield(source_task, source_port, sink_port, policy)
                    end
                end
                self
            end

            def has_concrete_input_connection?(required_port)
                each_concrete_input_connection(required_port) { return true }
                false
            end

            def each_concrete_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_concrete_output_connection, required_port)
                end

                each_output_connection(required_port) do |source_port, sink_port, sink_task, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if sink_task.kind_of?(Composition)
                        sink_task.each_concrete_output_connection(sink_port) do |_, sink_port, sink_task, connection_policy|
                            begin
                                this_policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in output chain for #{self}:#{source_port}: #{e.message}"
                            end
                            policy_copy = this_policy.dup
                            yield(source_port, sink_port, sink_task, this_policy)
                            if policy_copy != this_policy
                                connection_policy.clear
                                connection_policy.merge!(this_policy)
                            end
                        end
                    else
                        yield(source_port, sink_port, sink_task, policy)
                    end
                end
                self
            end

            def has_concrete_output_connection?(required_port)
                each_concrete_output_connection(required_port) { return true }
                false
            end

            # call-seq:
            #   source_task.each_output_connection { |source_port_name, sink_port_name, sink_port, policy| ...}
            #
            # Yield or enumerates the connections that exist getting out
            # of the ports of +source_task+. It does not include connections to
            # composition ports (i.e. exported ports): these connections are
            # followed until a concrete port (a port on an actual Orocos
            # task context) is found.
            #
            # If +required_port+ is given, it must be a port name, and only the
            # connections going out of this port will be yield.
            def each_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_output_connection, required_port)
                end

                each_sink do |sink_task, connections|
                    connections.each do |(source_port, sink_port), policy|
                        if required_port
                            if required_port == source_port
                                yield(source_port, sink_port, sink_task, policy)
                            end
                        else
                            yield(source_port, sink_port, sink_task, policy)
                        end
                    end
                end
                self
            end

            # Returns true if all the declared connections to the inputs of +task+ have been applied.
            # A given module won't be started until it is the case.
            #
            # If the +only_static+ flag is set to true, only ports that require
            # static connections will be considered
            def all_inputs_connected?
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    # Our source may not be initialized at all
                    if !source_task.orogen_task
                        return false
                    end

                    return false if !ActualDataFlow.linked?(source_task.orogen_task, orogen_task)
                    mappings = source_task.orogen_task[orogen_task, ActualDataFlow]
                    return false if !mappings.has_key?([source_port, sink_port])
                end
                true
            end
        end

        module Flows
            class << DataFlow
                # The set of connection changes that have been applied to the
                # DataFlow relation graph, but not yet applied on the actual
                # components (i.e. not yet present in the ActualDataFlow graph).
                attr_accessor :pending_changes
            end

            # Returns the set of tasks whose data flow has been changed that has
            # not yet been applied.
            def DataFlow.modified_tasks
                @modified_tasks ||= ValueSet.new
            end

            def DataFlow.add_relation(from, to, info)
                if !info.kind_of?(Hash)
                    raise ArgumentError, "the DataFlow relation requires a hash as info object"
                end

                super

                if !from.transaction_proxy? && !to.transaction_proxy?
                    if from.kind_of?(Orocos::RobyPlugin::TaskContext)
                        modified_tasks << from
                    end
		    if to.kind_of?(Orocos::RobyPlugin::TaskContext)
			modified_tasks << to
		    end
                end
            end

            def DataFlow.remove_relation(from, to)
                super

                if !from.transaction_proxy? && !to.transaction_proxy?
                    if from.kind_of?(Orocos::RobyPlugin::TaskContext)
                        modified_tasks << from
                    end
		    if to.kind_of?(Orocos::RobyPlugin::TaskContext)
			modified_tasks << to
		    end
                end
            end

            # Called by the relation graph management to update the DataFlow
            # edge information when connections are added or removed.
            def DataFlow.merge_info(source, sink, current_mappings, additional_mappings)
                super

                current_mappings.merge(additional_mappings) do |(from, to), old_options, new_options|
                    RobyPlugin.update_connection_policy(old_options, new_options)
                end
            end

            def DataFlow.updated_info(source, sink, mappings)
                super

                if !source.transaction_proxy? && !sink.transaction_proxy?
                    if source.kind_of?(Orocos::RobyPlugin::TaskContext)
                        modified_tasks << source
                    end
		    if sink.kind_of?(Orocos::RobyPlugin::TaskContext)
			modified_tasks << sink
		    end
                end
            end
        end

        RequiredDataFlow = ConnectionGraph.new
        RequiredDataFlow.name = "Orocos::RobyPlugin::RequiredDataFlow"
        RequiredDataFlow.extend Roby::Distributed::DRobyConstant::Dump
    end
end

