module Syskit
    module Models
        # A port attached to a component
        class Port
            # [ComponentModel] The component model this port is part of
            attr_reader :component_model
            # [Orocos::Spec::Port] The port model
            attr_reader :orogen_model
            # [String] The port name on +component_model+. It can be
            # different from orogen_model.name, as the port could be imported from
            # another component
            attr_accessor :name

            def initialize(component_model, orogen_model, name = orogen_model.name)
                @component_model, @name, @orogen_model =
                    component_model, name, orogen_model
            end

            def same_port?(other)
                other.kind_of?(Port) && (other.component_model <=> component_model) &&
                    other.orogen_model == orogen_model
            end

            def ==(other) # :nodoc:
                other.kind_of?(Port) && other.component_model == component_model &&
                other.orogen_model == orogen_model &&
                other.name == name
            end

            # Change the component model
            def attach(model)
                new_model = dup
                new_model.instance_variable_set(:@component_model, model)
                new_model
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

            def method_missing(*args, &block)
                orogen_model.send(*args, &block)
            end

            def short_name
                "#{component_model.short_name}.#{name}_port[#{type.name}]"
            end

            def to_s
                "#{component_model.short_name}.#{name}_port[#{type.name}]"
            end

            def pretty_print(pp)
                pp.text "port #{name} of "
                component_model.pretty_print(pp)
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


