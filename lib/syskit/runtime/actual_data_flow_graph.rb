# frozen_string_literal: true

module Syskit
    module Runtime
        # The graph that represents the connections on the actual ports
        #
        # I.e. this is the set of connections that really exist between our
        # components
        class ActualDataFlowGraph
            # Information about which ports are static and which are not. This
            # information is critical during disconnection to force
            # reconfiguration of the associated tasks
            #
            # @return [Hash<(Orocos::TaskContext,String),Boolean>]
            attr_reader :static_info

            def initialize
                @static_info = {}
                @graph = ConnectionGraph.new
            end

            def name=(name)
                @graph.name = name
            end

            # Registers a connection between two tasks
            #
            # @param [Orocos::TaskContext] source_task the task of the source
            #   port
            # @param [Orocos::TaskContext] sink_task the task of the sink
            #   port
            # @param [Hash] mappings the connections themselves
            # @option mappings [Boolean] force_update (false) whether the method
            #   should raise if the connection tries to be updated with a new
            #   incompatible policy, or whether it should be updated
            # @raise [Roby::ModelViolation] if the connection already exists
            #   with an incompatible policy
            #
            # Each element in the connection mappings represent one connection.
            # It is of the form
            #
            #    [source_port_name, sink_port_name] =>
            #       [policy, source_static, sink_static]
            #
            # where policy is a connection policy hash, and
            # source_static/sink_static are booleans indicating whether the
            # source (resp. sink) ports are static per {Port#static?}.
            #
            def add_connections(source_task, sink_task, mappings) # :nodoc:
                force_update = mappings.delete(:force_update)
                connections = add_connections_process_mappings(
                    source_task, sink_task, mappings
                )

                if !force_update || !@graph.has_edge?(source_task, sink_task)
                    @graph.add_connections(source_task, sink_task, connections)
                else
                    @graph.set_edge_info(
                        source_task, sink_task,
                        @graph.edge_info(source_task, sink_task).merge(connections)
                    )
                end
            end

            # @api private
            #
            # Internal helper for {#add_connections} that processes its mappings argument
            def add_connections_process_mappings(source_task, sink_task, mappings)
                connections = {}
                mappings.each do |(source_port, sink_port), info|
                    if info.size != 3
                        raise ArgumentError,
                              "ActualDataFlowGraph#add_connections expects " \
                              "the mappings to be of the form (source_port,sink_port) " \
                              "=> [policy, source_static, sink_static]"
                    end

                    policy, source_static, sink_static = *info
                    @static_info[[source_task, source_port]] = source_static
                    @static_info[[sink_task, sink_port]] = sink_static
                    connections[[source_port, sink_port]] = policy
                end
                connections
            end

            def remove_connections(source_task, sink_task, connections)
                @graph.remove_connections(source_task, sink_task, connections)
            end

            def clear
                @graph.clear
            end

            def empty?
                @graph.empty?
            end

            # Whether the given port is static (per {Port#static?}
            #
            # @param [Orocos::TaskContext] task
            # @param [String] port
            # @raise [ArgumentError] if the (task, port) pair is not registered
            def static?(task, port)
                static_info.fetch([task, port])
            rescue KeyError
                raise ArgumentError,
                      "no port #{port} on a task called #{task} is registered on #{self}"
            end

            # Returns whether two ports are connected
            def tasks_connected?(source_task, sink_task)
                @graph.has_edge?(source_task, sink_task)
            end

            # Returns information about the connections existing between two tasks
            #
            # @param [Orocos::TaskContext] source_task
            # @param [Orocos::TaskContext] sink_task
            # @return [{[String,String] => Hash}] mapping of (source_port,sink_port) pairs
            #    to the policy of the established connection
            def connections_of_tasks(source_task, sink_task)
                return {} unless @graph.has_edge?(source_task, sink_task)

                @graph.edge_info(source_task, sink_task)
            end

            # Returns whether two ports are connected
            def ports_connected?(source_task, source_port, sink_task, sink_port)
                @graph.has_edge?(source_task, sink_task) &&
                    @graph.edge_info(source_task, sink_task)
                          .key?([source_port, sink_port])
            end

            # List connections to the given ports
            #
            # @param [Orocos::Task] orocos_task the task whose input port we're inspecting
            # @param [Array<String>] port_name the name of the input port
            # @return [{[Orocos::Task,Orocos::Task] => Array<[String,String]>}] matching
            #   connections, as a mapping of (source_task, sink_task) to the port
            #   pair (as names)
            def input_connections_of_ports(orocos_task, port_names)
                @graph.each_in_neighbour(orocos_task)
                      .with_object({}) do |source_t, result|
                    mappings = @graph.edge_info(source_t, orocos_task)
                    result[[source_t, orocos_task]] =
                        mappings.each_key.find_all do |_, sink_p|
                            port_names.include?(sink_p)
                        end
                end
            end

            # Lists the tasks that are present in the graph
            def each_task
                @graph.each_vertex
            end

            # List connections from the given task
            #
            # @param [Orocos::Task] orocos_task the task whose output connections are
            #   expected
            # @return [{[Orocos::Task,Orocos::Task] => Array<[String,String]>}] matching
            #   connections, as a mapping of (source_task, sink_task) to the port
            #   pair (as names)
            def output_connections_of_task(orocos_task)
                @graph.each_out_neighbour(orocos_task).with_object({}) do |sink_t, result|
                    mappings = @graph.edge_info(orocos_task, sink_t)
                    result[[orocos_task, sink_t]] = mappings.keys
                end
            end

            # List connections from the given ports
            #
            # @param [Orocos::Task] orocos_task the task whose output ports
            #   we are inspecting
            # @param [Array<String>] port_names the names of the output ports
            # @return [{[Orocos::Task,Orocos::Task] => Array<[String,String]>}] matching
            #   connections, as a mapping of (source_task, sink_task) to the port
            #   pair (as names)
            def output_connections_of_ports(orocos_task, port_names)
                @graph.each_out_neighbour(orocos_task).with_object({}) do |sink_t, result|
                    mappings = @graph.edge_info(orocos_task, sink_t)
                    result[[orocos_task, sink_t]] =
                        mappings.each_key.find_all do |source_p, _|
                            port_names.include?(source_p)
                        end
                end
            end

            # List the connections to static input ports
            #
            # @param [Orocos::TaskContex] orocos_task
            # @return [{String=>Set<(Orocos::TaskContext,String)>}] mapping from a
            #   static input port of orocos_task to its sources, as pairs of tasks and
            #   port name
            def static_input_port_connections(orocos_task)
                @graph.each_in_neighbour(orocos_task)
                      .with_object({}) do |source_t, result|
                    connections = @graph.edge_info(source_t, orocos_task)
                    connections.each_key do |source_p, sink_p|
                        if static?(orocos_task, sink_p)
                            sources = (result[sink_p] ||= Set.new)
                            sources << [source_t, source_p]
                        end
                    end
                end
            end

            # List the connections to static output ports
            #
            # @param [Orocos::TaskContex] orocos_task
            # @return [{String=>Set<(Orocos::TaskContext,String)>}] mapping from a
            #   static output port of orocos_task to its sinks, as pairs of tasks and
            #   port name
            def static_output_port_connections(orocos_task)
                @graph.each_out_neighbour(orocos_task).with_object({}) do |sink_t, result|
                    connections = @graph.edge_info(orocos_task, sink_t)
                    connections.each_key do |source_p, sink_p|
                        if static?(orocos_task, source_p)
                            sinks = (result[source_p] ||= Set.new)
                            sinks << [sink_t, sink_p]
                        end
                    end
                end
            end

            # Return the internal graph structure
            def to_graph
                @graph
            end
        end
    end
end
