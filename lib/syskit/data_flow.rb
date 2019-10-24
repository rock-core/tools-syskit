module Syskit
    Flows = Roby::RelationSpace(Component)

    Flows.relation :DataFlow, child_name: :sink, parent_name: :source, dag: false,
                              weak: true, graph: ConnectionGraph
    DataFlow = Flows::DataFlow

    # Class out of which the Flows::DataFlow graph object is made
    #
    # see {ConnectionGraph} for a description of the roles of each connection
    # graph
    class DataFlow
        # The set of connection changes that have been applied to the
        # DataFlow relation graph, but not yet applied on the actual
        # components (i.e. not yet present in the ActualDataFlow graph).
        attr_accessor :pending_changes

        # Returns the set of tasks whose data flow has been changed that has
        # not yet been applied.
        #
        # It is maintained only on executable plans, through the
        # added/removed/updated hooks {TaskContext#added_sink},
        # {TaskContext#removed_sink}, {TaskContext#updated_sink},
        # {Composition#added_sink}, {Composition#removing_sink} and
        # {Composition#updated_sink}
        attr_reader :modified_tasks

        # If non-nil, this holds the set of concrete connections for this data
        # flow graph. It MUST be maintained by some external entity, and as such
        # is set only in contexts where the set of modifications to the graph is
        # known (e.g. {NetworkGeneration::MergeSolver}
        #
        # @return [ConnectionGraph,nil]
        attr_reader :concrete_connection_graph

        # The graph that provides policies between concrete tasks
        #
        # It is computed during network generation
        #
        # @return [Hash]
        attr_accessor :policy_graph

        def initialize(*args, **options)
            super
            @modified_tasks = Set.new
            @concrete_connection_graph = nil
            @policy_graph = {}
        end

        # @api private
        #
        # Graph class used to cache concrete connections once
        # {#enable_concrete_connection_graph} has been called
        class ConcreteConnectionGraph < ConnectionGraph
            def merge_info(source, sink, current_mappings, additional_mappings)
                current_mappings.merge(additional_mappings) do |_, old_options, new_options|
                    Syskit.update_connection_policy(old_options, new_options)
                end
            end
        end

        def enable_concrete_connection_graph(compute: true)
            @concrete_connection_graph =
                if compute
                    compute_concrete_connection_graph
                else
                    ConcreteConnectionGraph.new
                end
        end

        # @api private
        #
        # Computes the concrete connection graph from the DataFlow information
        def compute_concrete_connection_graph
            current_graph, @concrete_connection_graph = @concrete_connection_graph, nil
            graph = ConcreteConnectionGraph.new
            each_vertex do |task|
                next if !task.kind_of?(Syskit::TaskContext)

                task_to_task = Hash.new
                each_concrete_in_connection(task) do |source_task, source_port, sink_port, policy|
                    port_to_port = (task_to_task[source_task] ||= Hash.new)
                    port_to_port[[source_port, sink_port]] = policy
                end

                task_to_task.each do |source_task, mappings|
                    graph.add_edge(source_task, task, mappings)
                end
            end
            graph
        ensure
            @concrete_connection_graph = current_graph
        end

        def disable_concrete_connection_graph
            @concrete_connection_graph = nil
        end

        def concrete_connection_graph_enabled?
            !!@concrete_connection_graph
        end

        # Called by the relation graph management to update the DataFlow
        # edge information when connections are added or removed.
        def merge_info(source, sink, current_mappings, additional_mappings)
            current_mappings.merge(additional_mappings) do |_, old_options, new_options|
                Syskit.update_connection_policy(old_options, new_options)
            end
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
            mappings.each do |(out_port, in_port), options|
                source_task.ensure_has_output_port(out_port)
                sink_task.ensure_has_input_port(in_port)
            end
            super
        end

        ConnectionInPath = Struct.new :source_task, :source_port, :sink_task, :sink_port, :policy

        def each_concrete_in_path(task, port = nil)
            return enum_for(__method__, task, port) if !block_given?

            each_in_connection(task, port) do |source_task, source_port, sink_port, policy|
                connection = ConnectionInPath.new(source_task, source_port, task, sink_port, policy)

                # Follow the forwardings while +sink_task+ is a composition
                if source_task.kind_of?(Composition)
                    each_concrete_in_path(source_task, source_port) do |source_path, aggregated_policy|
                        begin
                            aggregated_policy = Syskit.update_connection_policy(policy, aggregated_policy)
                        rescue ArgumentError => e
                            raise SpecError, "incompatible policies in input chain for #{self}:#{sink_port}: #{e.message}"
                        end
                        aggregated_policy.freeze

                        yield(source_path + [connection], aggregated_policy)
                    end
                else
                    yield([connection], policy)
                end
            end
            self
        end

        def each_concrete_out_path(task, port = nil)
            return enum_for(__method__, task, port) if !block_given?

            each_out_connection(task, port) do |source_port, sink_port, sink_task, policy|
                connection = ConnectionInPath.new(task, source_port, sink_task, sink_port, policy)

                if sink_task.kind_of?(Composition)
                    each_concrete_out_path(sink_task, sink_port) do |sink_path, aggregated_policy|
                        begin
                            aggregated_policy = Syskit.update_connection_policy(policy, aggregated_policy)
                        rescue ArgumentError => e
                            raise SpecError, "incompatible policies in input chain for #{self}:#{sink_port}: #{e.message}"
                        end
                        aggregated_policy.freeze

                        yield([connection] + sink_path, aggregated_policy)
                    end
                else
                    yield([connection], policy)
                end
            end
            self
        end

        # Yield or enumerates the connections that exist towards the input
        # ports of self. It does not include connections to
        # composition ports (i.e. exported ports): these connections are
        # followed until a concrete port (a port on an actual
        # Syskit::TaskContext) is found.
        #
        # @param [#name,String,nil] port if non-nil, the port for
        #   which we want to enumerate the connections (in which case
        #   the sink_port yield parameter is guaranteed to be this name).
        #   Otherwise, all ports are enumerated.
        #
        # @yield each connections
        # @yieldparam [Syskit::TaskContext] source_task the source task in
        #   the connection
        # @yieldparam [String] source_port the source port name on source_task
        # @yieldparam [String] sink_port the sink port name on self. If
        #   the port argument is non-nil, it is guaranteed to be the
        #   same.
        # @yieldparam [Hash] policy the connection policy
        #
        # @see each_input_connection each_concrete_output_connection
        #   each_output_connection
        def each_concrete_in_connection(task, port = nil)
            return enum_for(__method__, task, port) if !block_given?

            if concrete_connection_graph
                return concrete_connection_graph.each_in_connection(task, port, &proc)
            else
                each_concrete_in_path(task, port) do |path, aggregated_policy|
                    first_conn = path.first
                    last_conn  = path.last
                    yield(first_conn.source_task, first_conn.source_port, last_conn.sink_port, aggregated_policy)
                end
            end

            self
        end

        # Yield or enumerates the connections that exist from the output
        # ports of self. It does not include connections to
        # composition ports (i.e. exported ports): these connections are
        # followed until a concrete port (a port on an actual
        # Syskit::TaskContext) is found.
        #
        # @param [#name,String,nil] port if non-nil, the port for
        #   which we want to enumerate the connections (in which case
        #   the source_port yield parameter is guaranteed to be this name).
        #   Otherwise, all ports are enumerated.
        #
        # @yield each connections
        # @yieldparam [String] source_port the source port name on self. If
        #   the port argument is non-nil, it is guaranteed to be the
        #   same.
        # @yieldparam [String] sink_port the sink port name on sink_task.
        # @yieldparam [Syskit::TaskContext] sink_task the sink task in
        #   the connection
        # @yieldparam [Hash] policy the connection policy
        #
        # @see each_concrete_input_connection each_input_connection
        #   each_output_connection
        def each_concrete_out_connection(task, port = nil)
            return enum_for(__method__, task, port) if !block_given?

            if concrete_connection_graph
                return concrete_connection_graph.each_out_connection(task, port, &proc)
            else
                each_concrete_out_path(task, port) do |path, aggregated_policy|
                    first_conn = path.first
                    last_conn  = path.last
                    yield(first_conn.source_port, last_conn.sink_port, last_conn.sink_task, aggregated_policy)
                end
            end
            self
        end

        # Methods that are mixed-in Syskit::Component to help with connection
        # management
        module Extension
            class NotOutputPort < ArgumentError; end
            class NotInputPort < ArgumentError; end
            class NotComposition < ArgumentError; end

            # Makes sure that +self+ has an output port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_output_port(name)
                if !model.find_output_port(name)
                    raise NotOutputPort, "#{self} has no output port called #{name}"
                end
            end

            # Makes sure that +self+ has an input port called +name+. It will
            # instanciate a dynamic port if needed.
            #
            # Raises ArgumentError if no such port can ever exist on +self+
            def ensure_has_input_port(name)
                if !model.find_input_port(name)
                    raise NotInputPort, "#{self} has no input port called #{name}"
                end
            end

            # Forward an input of self to an input port of another task
            def forward_input_ports(task, mappings)
                if !fullfills?(Composition)
                    raise NotComposition, "#{self} is not a composition"
                elsif mappings.empty?
                    return
                end

                mappings.each do |(from, to), options|
                    ensure_has_input_port(from)
                    task.ensure_has_input_port(to)
                end
                add_sink(task, mappings)
            end

            def forward_output_ports(task, mappings)
                if !task.fullfills?(Composition)
                    raise NotComposition, "#{self} is not a composition"
                elsif mappings.empty?
                    return
                end

                mappings.each do |(from, to), options|
                    ensure_has_output_port(from)
                    task.ensure_has_output_port(to)
                end
                add_sink(task, mappings)
            end

            # Returns true if +port_name+ is connected
            def connected?(port_name)
                dataflow_graph = relation_graph_for(Flows::DataFlow)
                dataflow_graph.has_out_connections?(self, port_name) ||
                    dataflow_graph.has_in_connections?(self, port_name)
            end


            # Tests if +port_name+ is connected to +other_port+ on +other_task+
            def connected_to?(port_name, other_task, other_port)
                relation_graph_for(Flows::DataFlow).
                    connected?(self, port_name, other_task, other_port)
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
            def connect_ports(sink_task, mappings)
                return if mappings.empty?

                mappings.each do |(out_port, in_port), options|
                    ensure_has_output_port(out_port)
                    sink_task.ensure_has_input_port(in_port)
                end
                add_sink(sink_task, mappings)
            end

            def disconnect_ports(sink_task, mappings)
                mappings.each do |out_port, in_port|
                    ensure_has_output_port(out_port)
                    sink_task.ensure_has_input_port(in_port)
                end
                relation_graph_for(Flows::DataFlow).
                    remove_connections(self, sink_task, mappings)
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

            # Yield or enumerates the connections that exist towards the input
            # ports of self.
            #
            # @param [#name,String,nil] port if non-nil, the port for
            #   which we want to enumerate the connections (in which case
            #   the sink_port yield parameter is guaranteed to be this name).
            #   Otherwise, all ports are enumerated.
            #
            # @yield each connections
            # @yieldparam [Syskit::TaskContext] source_task the source task in
            #   the connection
            # @yieldparam [String] source_port the source port name on source_task
            # @yieldparam [String] sink_port the sink port name on self. If
            #   the port argument is non-nil, it is guaranteed to be the
            #   same.
            # @yieldparam [Hash] policy the connection policy
            #
            # @see each_concrete_input_connection each_concrete_output_connection
            #   each_output_connection
            def each_input_connection(port = nil, &block)
                relation_graph_for(Flows::DataFlow).
                    each_in_connection(self, port, &block)
            end

            def each_concrete_input_connection(port = nil, &block)
                relation_graph_for(Flows::DataFlow).
                    each_concrete_in_connection(self, port, &block)
            end

            # Tests if an input port or any input ports is connected to an
            # actual task (ignoring composition exports)
            #
            # @param [#name,String,nil] port if non-nil, only
            #   connections involving this port will be tested against.
            #   Otherwise, the method tests for any inbound connection to
            #   self
            # @return [Boolean] true if the given port, or the task, is
            #   connected to something by an inbound connection
            def has_concrete_input_connection?(port)
                each_concrete_input_connection(port) { return true }
                false
            end

            def each_concrete_output_connection(port = nil, &block)
                relation_graph_for(Flows::DataFlow).
                    each_concrete_out_connection(self, port, &block)
            end

            # Tests if an output port or any output ports is connected to an
            # actual task (ignoring composition exports)
            #
            # @param [#name,String,nil] port if non-nil, only
            #   connections involving this port will be tested against.
            #   Otherwise, the method tests for any outbound connection to
            #   self
            # @return [Boolean] true if the given port, or the task, is
            #   connected to something by an outbound connection
            def has_concrete_output_connection?(port)
                each_concrete_output_connection(port) { return true }
                false
            end

            # Yield or enumerates the connections that exist from the output ports
            # of self.
            #
            # @param (see ConnectionGraph#each_out_connection)
            # @yield (see ConnectionGraph#each_out_connection)
            # @yieldparam (see ConnectionGraph#each_out_connection)
            def each_output_connection(port = nil, &block)
                relation_graph_for(Flows::DataFlow).
                    each_out_connection(self, port, &block)
            end

            # Returns true if all the declared connections to the inputs of +task+ have been applied.
            # A given module won't be started until it is the case.
            #
            # If the +only_static+ flag is set to true, only ports that require
            # static connections will be considered
            def all_inputs_connected?(only_static: false)
                logger = Runtime::ConnectionManagement
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    # Our source may not be initialized at all
                    if !source_task.orocos_task
                        logger.debug do
                            logger.debug "missing input connection because the source task is not ready on port #{sink_port} of"
                            logger.log_pp :debug, self
                            logger.log_nest(2) do
                                logger.debug "connection expected to port #{source_port} of"
                                logger.log_pp :debug, source_task
                            end
                            break
                        end
                        return false
                    end
                    if only_static && !concrete_model.find_input_port(sink_port)
                        next
                    end

                    is_connected =
                        ActualDataFlow.has_edge?(source_task.orocos_task, orocos_task) &&
                        ActualDataFlow.edge_info(source_task.orocos_task, orocos_task).
                            has_key?([source_port, sink_port])

                    if !is_connected
                        logger.debug do
                            logger.debug "missing input connection on port #{sink_port} of"
                            logger.log_pp :debug, self
                            logger.log_nest(2) do
                                logger.debug "  connection expected to port #{source_port} of"
                                logger.log_pp :debug, source_task
                            end
                            break
                        end
                        return false
                    end
                end
                true
            end
        end
    end
end
