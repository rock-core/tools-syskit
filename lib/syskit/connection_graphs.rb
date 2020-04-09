# frozen_string_literal: true

module Syskit
    # (see ConnectionGraph)
    ActualDataFlow = ActualDataFlowGraph.new
    ActualDataFlow.name = "Syskit::ActualDataFlow"
    ActualDataFlow.extend Roby::DRoby::V5::DRobyConstant::Dump

    # (see ConnectionGraph)
    RequiredDataFlow = ConnectionGraph.new
    RequiredDataFlow.name = "Syskit::RequiredDataFlow"
    RequiredDataFlow.extend Roby::DRoby::V5::DRobyConstant::Dump

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
        fallback =
            if old_fallback && new_fallback
                update_connection_policy(old_fallback, new_fallback)
            else
                old_fallback || new_fallback
            end

        old = Orocos::Port.validate_policy(old)
        new = Orocos::Port.validate_policy(new)

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
            elsif key == :size
                [old_value, new_value].max
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
            Models.debug "resolving connections from #{output_ports.map(&:name).sort.join(',')} to #{input_ports.map(&:name).sort.join(',')}"
            break
        end

        result = []
        matched_input_ports = Set.new

        # First resolve the exact matches
        remaining_outputs = output_ports.dup
        remaining_outputs.delete_if do |out_port|
            in_port = input_ports
                      .find do |in_port|
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
            candidates = input_ports
                         .find_all { |in_port| in_port.type == out_port.type }
            if candidates.size > 1
                filtered_candidates = candidates
                                      .find_all { |p| !matched_input_ports.include?(p) }
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

        # Finally, verify that we autoconnect multiple outputs to a single
        # input only if it is a multiplexing port
        outputs_per_input = {}
        result.each do |out_port, in_port|
            if outputs_per_input[in_port]
                unless in_port.multiplexes?
                    candidates = result.map { |o, i| o if i == in_port }
                                       .compact
                    raise AmbiguousAutoConnection.new(in_port, candidates)
                end
            end
            outputs_per_input[in_port] = out_port
        end

        Models.debug do
            result.each do |out_port, in_port|
                Models.debug "  #{out_port.name} => #{in_port.name}"
            end
            unless remaining_outputs.empty?
                Models.debug "  no matches found for outputs #{remaining_outputs.map(&:name).sort.join(',')}"
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
end
