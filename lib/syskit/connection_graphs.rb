module Syskit
        # Represents the actual connection graph between task context proxies.
        # Its vertices are instances of Orocos::TaskContext, and edges are
        # mappings from [source_port_name, sink_port_name] pairs to the
        # connection policy between these ports.
        #
        # Syskit::ActualDataFlow is the actual global graph instance
        # in which the overall system connections are maintained in practice
        class ConnectionGraph < BGL::Graph
            # Needed for Roby's marshalling (so that we can dump the connection
            # graph as a constant)
            attr_reader :name

            def name=(name)
                super
                @name = name
            end

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
        ActualDataFlow.name = "Syskit::ActualDataFlow"
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

        # Resolves possible connections between a set of output ports and a set
        # of input ports
        #
        # @param [Array<Port>] output_ports the set of output ports
        # @param [Array<Port>] input_ports the set of output ports
        # @return [Array<(Port,Port)>] the set of connections
        # @raise [AmbiguousAutoConnection] if more than one input port is found
        #   for a given output port
        def self.resolve_connections(output_ports, input_ports)
            Models.debug do
                Models.debug "resolving connections from #{output_ports.map(&:name).sort.join(",")} to #{input_ports.map(&:name).sort.join(",")}"
                break
            end

            result = Array.new
            matched_input_ports = Set.new

            # First resolve the exact matches
            remaining_outputs = output_ports.dup
            remaining_outputs.delete_if do |out_port|
                in_port = input_ports.
                    find do |in_port|
                        in_port.name == out_port.name &&
                            in_port.type == out_port.type
                    end
                if in_port
                    result << [out_port, in_port]
                    matched_input_ports << in_port
                    true
                end
            end

            # In the second stage, we match by type. If there are ambiguities,
            # we try to resolve them by excluding the ports that had an exact
            # match. This is, by experience, expected behaviour in practice
            remaining_outputs.each do |out_port|
                candidates = input_ports.
                    find_all { |in_port| in_port.type == out_port.type }
                if candidates.size > 1
                    filtered_candidates = candidates.
                        find_all { |p| !matched_input_ports.include?(p) }
                    if filtered_candidates.size == 1
                        candidates = filtered_candidates
                    end
                end
                if candidates.size > 1
                    raise AmbiguousAutoConnection.new(out_port, candidates)
                elsif candidates.size == 1
                    result << [out_port, candidates.first]
                end
            end

            Models.debug do
                result.each do |out_port, in_port|
                    Models.debug "  #{out_port.name} => #{in_port.name}"
                end
                if !remaining_outputs.empty?
                    Models.debug "  no matches found for outputs #{remaining_outputs.map(&:name).sort.join(",")}"
                end
                break
            end
            result
        end

        # Generic implementation of connection handling
        #
        # This is used to connect everything that can be connected: component
        # and service instances, composition child models. The method resolves
        # both source and sinks as a set of ports using #each_output_port and
        # #each_input_port if they are not plain ports, finds which connections
        # need to be created using {Syskit.resolve_connections} and then calls
        # output_port.connect_to input_port for each of these connections.
        #
        # @param [Port,Models::Port,#each_output_port] source the source part of
        #   the connection
        # @param [Port,Models::Port,#each_input_port] sink the sink part of the
        #   connection
        # @param [Hash] policy the connection policy
        # @return [Array<(Port,Port)>] the set of connections actually created
        # @raise (see Syskit.resolve_connections)
        def self.connect(source, sink, policy)
            output_ports =
                if source.respond_to?(:each_output_port)
                    source.each_output_port.to_a
                else [source]
                end
            input_ports =
                if sink.respond_to?(:each_input_port)
                    sink.each_input_port.to_a
                else [sink]
                end

            connections = resolve_connections(output_ports, input_ports)
            if connections.empty?
                raise InvalidAutoConnection.new(source, sink) 
            end

            connections.each do |out_port, in_port|
                out_port.connect_to in_port, policy
            end

            connections
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

            def may_have_output_port?(name)
                model.find_output_port(name) ||
                    model.has_dynamic_output_port?(name)
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

            def may_have_input_port?(name)
                model.find_input_port(name) ||
                    model.has_dynamic_input_port?(name)
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
                    if mappings.any? { |(from, to), _| to == port_name }
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
                mappings.each do |(out_port, in_port), options|
                    ensure_has_output_port(out_port)
                    target_task.ensure_has_input_port(in_port)
                end

                add_sink(target_task, mappings)
            end

            def disconnect_ports(target_task, mappings)
                if !Flows::DataFlow.linked?(self, target_task)
                    raise ArgumentError, "no such connections #{mappings} for #{self} => #{target_task}"
                end

                connections = self[target_task, Flows::DataFlow]

                result = Hash.new
                mappings.delete_if do |port_pair|
                    if !port_pair.respond_to?(:to_ary)
                        raise ArgumentError, "invalid connection description #{mappings.inspect}, expected a list of pairs of port names"
                    end
                    result[port_pair] = connections.delete(port_pair)
                end
                if !mappings.empty?
                    raise ArgumentError, "no such connections #{mappings.map { |pair| "#{pair[0]} => #{pair[1]}" }.join(", ")} for #{self} => #{target_task}. Existing connections are: #{connections.map { |pair| "#{pair[0]} => #{pair[1]}" }.join(", ")}"
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
                Flows::DataFlow.modified_tasks << self << target_task
            end

            # Calls either #connect_ports or #forward_ports, depending on its
            # arguments
            #
            # It calls #forward_ports only if one of [target_task, self] is a
            # composition and the other is part of this composition. Otherwise,
            # calls #connect_ports
            def connect_or_forward_ports(target_task, mappings)
                if !kind_of?(Composition) && !target_task.kind_of?(Composition)
                    return connect_ports(target_task, mappings)
                end

                connections = Hash.new
                forwards   = Hash.new
                mappings.each do |(out_port_name, in_port_name), policy|
                    source_has_output = may_have_output_port?(out_port_name)
                    target_has_input  = target_task.may_have_input_port?(in_port_name)
                    if source_has_output && target_has_input
                        connections[[out_port_name, in_port_name]] = policy
                        next
                    end

                    if kind_of?(Composition)
                        source_has_input = may_have_input_port?(out_port_name)
                        if source_has_input
                            forwards[[out_port_name, in_port_name]] = policy
                            next
                        elsif !source_has_output
                            raise ArgumentError, "#{out_port_name} is neither an output port nor an exported input of #{self}"
                        end
                    elsif !source_has_output
                        raise ArgumentError, "#{out_port_name} is not an output port of #{self}"
                    end

                    if target_task.kind_of?(Composition)
                        target_has_output = target_task.may_have_output_port?(in_port_name)
                        if target_has_output
                            forwards[[out_port_name, in_port_name]] = policy
                            next
                        elsif !target_has_input
                            raise ArgumentError, "#{out_port_name} is neither an input port nor an exported output of #{self}"
                        end
                    elsif !target_has_input
                        raise ArgumentError, "#{out_port_name} is not an input port of #{self}"
                    end

                    raise ArgumentError, "invalid connection #{self}.#{out_port_name} => #{target_task}.#{in_port_name}"
                end

                if !connections.empty?
                    connect_ports(target_task, connections)
                end
                if !forwards.empty?
                    forward_ports(target_task, forwards)
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
                                this_policy = Syskit.update_connection_policy(policy, connection_policy)
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
                                this_policy = Syskit.update_connection_policy(policy, connection_policy)
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
                    if !source_task.orocos_task
                        return false
                    end

                    return false if !ActualDataFlow.linked?(source_task.orocos_task, orocos_task)
                    mappings = source_task.orocos_task[orocos_task, ActualDataFlow]
                    return false if !mappings.has_key?([source_port, sink_port])
                end
                true
            end

            def finalized!(timestamp = nil)
                plan = self.plan
                super

                # Do not remove if we are on a running plan. The connection
                # management code needs to look at these tasks to actually
                # disconnect them
                if !plan.executable? || !plan.engine
                    Flows::DataFlow.modified_tasks.delete(self)
                end
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
                    if from.kind_of?(Syskit::TaskContext)
                        modified_tasks << from
                    end
		    if to.kind_of?(Syskit::TaskContext)
			modified_tasks << to
		    end
                end
            end

            def DataFlow.remove_relation(from, to)
                super

                if !from.transaction_proxy? && !to.transaction_proxy?
                    if from.kind_of?(Syskit::TaskContext)
                        modified_tasks << from
                    end
		    if to.kind_of?(Syskit::TaskContext)
			modified_tasks << to
		    end
                end
            end

            # Called by the relation graph management to update the DataFlow
            # edge information when connections are added or removed.
            def DataFlow.merge_info(source, sink, current_mappings, additional_mappings)
                super

                current_mappings.merge(additional_mappings) do |(from, to), old_options, new_options|
                    Syskit.update_connection_policy(old_options, new_options)
                end
            end

            def DataFlow.updated_info(source, sink, mappings)
                super

                if !source.transaction_proxy? && !sink.transaction_proxy?
                    if source.kind_of?(Syskit::TaskContext)
                        modified_tasks << source
                    end
		    if sink.kind_of?(Syskit::TaskContext)
			modified_tasks << sink
		    end
                end
            end
        end

        RequiredDataFlow = ConnectionGraph.new
        RequiredDataFlow.name = "Syskit::RequiredDataFlow"
        RequiredDataFlow.extend Roby::Distributed::DRobyConstant::Dump
end

