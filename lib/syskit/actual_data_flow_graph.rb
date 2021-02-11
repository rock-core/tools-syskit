# frozen_string_literal: true

module Syskit
    # The graph that represents the connections on the actual ports
    #
    # I.e. this is the set of connections that really exist between our
    # components
    class ActualDataFlowGraph < ConnectionGraph
        # Information about which ports are static and which are not. This
        # information is critical during disconnection to force
        # reconfiguration of the associated tasks
        #
        # @return [Hash<(Orocos::TaskContext,String),Boolean>]
        attr_reader :static_info

        def initialize(*)
            super
            @static_info = {}
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
        #    [source_port_name, sink_port_name] => [policy, source_static, sink_static]
        #
        # where policy is a connection policy hash, and
        # source_static/sink_static are booleans indicating whether the
        # source (resp. sink) ports are static per {Port#static?}.
        #
        def add_connections(source_task, sink_task, mappings) # :nodoc:
            force_update = mappings.delete(:force_update)
            connections = {}
            mappings.each do |(source_port, sink_port), info|
                if info.size != 3
                    raise ArgumentError,
                          "ActualDataFlowGraph#add_connections expects "\
                          "the mappings to be of the form (source_port,sink_port) "\
                          "=> [policy, source_static, sink_static]"
                end

                policy, source_static, sink_static = *info
                static_info[[source_task, source_port]] = source_static
                static_info[[sink_task, sink_port]] = sink_static
                connections[[source_port, sink_port]] = policy
            end

            if !force_update || !has_edge?(source_task, sink_task)
                super(source_task, sink_task, connections)
            else
                set_edge_info(source_task, sink_task,
                              edge_info(source_task, sink_task).merge(connections))
            end
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
    end
end
