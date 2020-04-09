# frozen_string_literal: true

module Syskit
    module Models
        # Representation of a component port on a component instance.
        #
        # The sibling class Syskit::Port represents a port on a component
        # instance. For instance, an object of class Syskit::Models::Port could
        # be used to represent a port on a subclass of TaskContext while
        # Syskit::Port would represent it for an object of that subclass.
        class Port
            # @return [ComponentModel] The component model this port is part of
            attr_reader :component_model
            # @return [Orocos::Spec::Port] The port model
            attr_reader :orogen_model
            # @return [String] The port name on +component_model+. It can be
            #   different from orogen_model.name, as the port could be imported
            #   from another component
            attr_accessor :name
            # @return [Model<Typelib::Type>] the typelib type of this port
            attr_reader :type

            # @param [#instanciate] component_model the component model
            # @param [Orocos::Spec::Port] orogen_model the oroGen port model
            # @param [String] name the port name if it is different than the
            #   name in 'orogen_model'
            def initialize(component_model, orogen_model, name = orogen_model.name)
                @component_model = component_model
                @name = name
                @orogen_model = orogen_model

                @type =
                    if orogen_model.type.contains_opaques?
                        Orocos.default_loader.intermediate_type_for(orogen_model.type)
                    else
                        orogen_model.type
                    end

                @max_sizes = orogen_model.max_sizes
                                         .merge(Orocos.max_sizes_for(type))
            end

            def max_marshalling_size
                OroGen::Spec::OutputPort.compute_max_marshalling_size(type, max_sizes)
            end

            attr_reader :max_sizes

            # Whether this port and the argument represent the same port
            def same_port?(other)
                other.kind_of?(Port) && (other.component_model <=> component_model) &&
                    other.orogen_model == orogen_model
            end

            # Whether this port and the argument are the same port
            def ==(other)
                other.kind_of?(self.class) && other.component_model == component_model &&
                other.orogen_model == orogen_model &&
                other.name == name
            end

            # Return a new port attached to another component model
            #
            # @return [Port]
            def attach(model)
                new_model = dup
                new_model.instance_variable_set(:@component_model, model)
                new_model
            end

            # Try to resolve, if possible, the Port object corresponding to
            # self, in which {#component_model} is a "proper" component model
            # (i.e. a subclass of Component and not a data service)
            #
            # If it is not possible, returns self
            #
            # @return [Port]
            def try_to_component_port
                if component_model.respond_to?(:self_port_to_component_port)
                    component_model.self_port_to_component_port(self)
                else self
                end
            end

            # Returns the Port object corresponding to self, in which
            # {#component_model} is a "proper" component model (i.e. a subclass
            # of Component and not a data service)
            #
            # @return [Port]
            # @raise [ArgumentError] if self cannot be resolved into a component
            #   port
            def to_component_port
                if component_model.respond_to?(:self_port_to_component_port)
                    component_model.self_port_to_component_port(self)
                else raise ArgumentError, "cannot resolve a port of #{component_model.short_name} into a component port"
                end
            end

            # Connects this port to the other given port, using the given policy
            #
            # @raise [WrongPortConnectionTypes]
            # @raise [WrongPortConnectionDirection]
            # @raise [SelfConnection]
            def connect_to(in_port, policy = {})
                out_port = to_component_port
                if out_port == self
                    if in_port.respond_to?(:to_component_port)
                        in_port = in_port.to_component_port
                        if !out_port.output?
                            raise WrongPortConnectionDirection.new(self, in_port), "cannot connect #{out_port} to #{in_port}: #{out_port} is not an output port"
                        elsif !in_port.input?
                            raise WrongPortConnectionDirection.new(self, in_port), "cannot connect #{out_port} to #{in_port}: #{in_port} is not an input port"
                        elsif out_port.component_model == in_port.component_model
                            raise SelfConnection.new(out_port, in_port), "cannot connect #{out_port} to #{in_port}: they are both ports of the same component"
                        elsif out_port.type != in_port.type
                            raise WrongPortConnectionTypes.new(self, in_port), "cannot connect #{out_port} to #{in_port}: types mismatch"
                        end

                        component_model.connect_ports(in_port.component_model, [out_port.name, in_port.name] => policy)
                    else
                        Syskit.connect self, in_port, policy
                    end

                else
                    out_port.connect_to(in_port, policy)
                end
            end

            # Tests whether self is connected to the provided port
            def connected_to?(sink_port)
                source_port = try_to_component_port
                if source_port == self
                    sink_port = sink_port.try_to_component_port
                    component_model.connected?(source_port, sink_port)
                else
                    source_port.connected_to?(sink_port)
                end
            end

            # Tests whether this port can be connceted to the provided input
            # port
            def can_connect_to?(sink_port)
                source_port = try_to_component_port
                if source_port == self
                    sink_port = sink_port.try_to_component_port
                    output? && sink_port.input? && type == sink_port.type
                else
                    source_port.can_connect_to?(sink_port)
                end
            end

            def respond_to_missing?(m, include_private)
                if !OROGEN_MODEL_EXCLUDED_FORWARDINGS.include?(m) && orogen_model.respond_to?(m)
                    true
                else super
                end
            end

            OROGEN_MODEL_EXCLUDED_FORWARDINGS = [:task].freeze

            def method_missing(m, *args, &block)
                if !OROGEN_MODEL_EXCLUDED_FORWARDINGS.include?(m) && orogen_model.respond_to?(m)
                    orogen_model.public_send(m, *args, &block)
                else super
                end
            end

            def short_name
                "#{component_model.short_name}.#{name}_port[#{type.name}]"
            end

            def to_s
                "#{component_model.short_name}.#{name}_port[#{type.name}]"
            end

            def pretty_print(pp)
                pp.text "port '#{name}' of "
                pp.nest(2) do
                    pp.breakable
                    component_model.pretty_print(pp)
                    pp.breakable
                    pp.text "Defined with"
                    pp.nest(2) do
                        pp.breakable
                        orogen_model.pretty_print(pp)
                    end
                end
            end

            def to_orocos_port(component)
                component_model.bind(component).find_port(name)
            end

            def static?
                orogen_model.static?
            end

            def new_sample
                orogen_model.type.new
            end

            def instanciate(plan)
                bind(component_model.instanciate(plan))
            end

            def resolve_data_source(context)
                if context.kind_of?(Roby::Plan)
                    context.add(context = component_model.as_plan)
                end
                bind(context).to_data_source
            end

            # @return [Boolean] true if this is an output port, false otherwise.
            #   The default implementation returns false
            def output?
                false
            end

            # @return [Boolean] true if this is an input port, false otherwise.
            #   The default implementation returns false
            def input?
                false
            end
        end

        class OutputPort < Port
            # This is needed to use the Port to represent a data
            # source on the component's state as e.g.
            #
            #   state.position = Component.pose_samples_port
            #
            def to_state_variable_model(field, name)
                model = Roby::StateVariableModel.new(field, name)
                model.type = type
                model.data_source = self
                model
            end

            def bind(component)
                Syskit::OutputPort.new(self, component_model.bind(component))
            end

            def output?
                true
            end

            def reader(policy = {})
                OutputReader.new(self, policy)
            end
        end

        class InputPort < Port
            # Return true if the underlying port multiplexes, i.e. if it is
            # an input port that is expected to have multiple inbound
            # connections
            def multiplexes?
                orogen_model.multiplexes?
            end

            def bind(component)
                Syskit::InputPort.new(self, component_model.bind(component))
            end

            def writer(policy = {})
                InputWriter.new(self, policy)
            end

            def input?
                true
            end
        end

        class OutputReader
            attr_reader :port
            attr_reader :policy

            def initialize(port, policy = {})
                @port = port
                @policy = policy
            end

            def hash
                [port, policy].hash
            end

            def eql?(other)
                self == other
            end

            def bind(port_or_task)
                if port_or_task.respond_to?(:reader)
                    port_or_task.reader(policy)
                else
                    port.bind(port_or_task).reader(policy)
                end
            end

            def instanciate(plan)
                port.instanciate(plan).reader(policy)
            end

            def ==(other)
                other.kind_of?(OutputReader) &&
                    other.port == port &&
                    other.policy == policy
            end
        end

        class InputWriter
            attr_reader :port
            attr_reader :policy

            def initialize(port, policy = {})
                @port = port
                @policy = policy
            end

            def hash
                [port, policy].hash
            end

            def eql?(other)
                self == other
            end

            def bind(port_or_task)
                if port_or_task.respond_to?(:writer)
                    port_or_task.writer(policy)
                else
                    port.bind(port_or_task).writer(policy)
                end
            end

            def instanciate(plan)
                port.instanciate(plan).writer(policy)
            end

            def new_sample
                port.new_sample
            end

            def ==(other)
                other.kind_of?(InputWriter) &&
                    other.port == port &&
                    other.policy == policy
            end
        end
    end
end
