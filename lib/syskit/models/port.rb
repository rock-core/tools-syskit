module Syskit
    module Models
        # Representation of a component port on a component instance.
        #
        # The sibling class Syskit::Port represents a port on a component
        # instance. For instance, an object of class Syskit::Models::Port could
        # be used to represent a port on a subclass of TaskContext while
        # Syskit::Port would represent it for an object of that subclass.
        class Port
            # [ComponentModel] The component model this port is part of
            attr_reader :component_model
            # [Orocos::Spec::Port] The port model
            attr_reader :orogen_model
            # [String] The port name on +component_model+. It can be
            # different from orogen_model.name, as the port could be imported from
            # another component
            attr_accessor :name

            # @param [#instanciate] component_model the component model
            # @param [Orocos::Spec::Port] orogen_model the oroGen port model
            # @param [String] name the port name if it is different than the
            #   name in 'orogen_model'
            def initialize(component_model, orogen_model, name = orogen_model.name)
                @component_model, @name, @orogen_model =
                    component_model, name, orogen_model
            end

            def same_port?(other)
                other.kind_of?(Port) && (other.component_model <=> component_model) &&
                    other.orogen_model == orogen_model
            end

            def ==(other)
                other.kind_of?(self.class) && other.component_model == component_model &&
                other.orogen_model == orogen_model &&
                other.name == name
            end

            # Change the component model
            def attach(model)
                new_model = dup
                new_model.instance_variable_set(:@component_model, model)
                new_model
            end

            # Returns the Port object corresponding to self, in which
            # {#component_model} is a "proper" component model (i.e. a subclass
            # of Component and not a data service)
            #
            # @return [Port]
            def to_component_port
                if component_model.respond_to?(:self_port_to_component_port)
                    component_model.self_port_to_component_port(self)
                else raise ArgumentError, "cannot resolve a port of #{component_model.short_name} into a component port"
                end
            end

            # Connects this port to the other given port, using the given policy
            def connect_to(in_port, policy = Hash.new)
                out_port = self.to_component_port
                if out_port == self
                    in_port = in_port.to_component_port
                    component_model.connect_ports(in_port.component_model, [out_port.name, in_port.name] => policy)
                else
                    out_port.connect_to(in_port, policy)
                end
            end

            def actual_name
                orogen_model.name
            end

            def type
                orogen_model.type
            end

            def respond_to?(m, *args)
                super || orogen_model.respond_to?(m, *args)
            end

            def method_missing(m, *args, &block)
                if orogen_model.respond_to?(m)
                    orogen_model.send(m, *args, &block)
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
                component_model.resolve(component).find_port(name)
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
                Syskit::OutputPort.new(self, component)
            end

            def resolve_data_source(context)
                if context.kind_of?(Roby::Plan)
                    context.add(context = component_model.as_plan)
                end
                bind(context).to_data_source
            end
        end

        class InputPort < Port
            def bind(component)
                Syskit::InputPort.new(self, component)
            end

            # Return true if the underlying port multiplexes, i.e. if it is
            # an input port that is expected to have multiple inbound
            # connections
            def multiplexes?
                orogen_model.multiplexes?
            end
        end
    end
end


