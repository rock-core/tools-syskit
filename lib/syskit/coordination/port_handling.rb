module Syskit
    module Coordination
        # Port access code for instance-level task objects
        module PortHandling
            def find_port(port_name)
                if model_port = model.find_port(port_name)
                    case model_port
                    when Syskit::Models::OutputPort
                        OutputPort.new(model_port, model_port.component_model.bind(self))
                    when Syskit::Models::InputPort
                        InputPort.new(model_port, model_port.component_model.bind(self))
                    end
                end
            end

            def self_port_to_component_port(port)
                port_model   = port.model
                model_object = port_model.component_model
                component_model = model_object.model

                if respond_to?(:parent)
                    component_model.resolve(parent.resolve).self_port_to_component_port(port)
                else
                    component_model.resolve(self.resolve).self_port_to_component_port(port)
                end
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /(.*)_port$/
                    port_name = $1
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                    elsif port = find_port(port_name)
                        return port
                    else
                        raise NoMethodError.new("#{self} has no port called #{port_name}", m)
                    end
                end
                super
            end
        end

        class OutputPort < Syskit::OutputPort
            def reader(policy = Hash.new)
                # The 'rescue' case is used only on first evaluation of the
                # block, when Roby instanciates it to check syntax.
                # The script blocks have to be re-instanciated for each
                # task they get applied on
                begin
                    component.resolve
                    super
                rescue Roby::Coordination::ResolvingUnboundObject
                    Syskit::Models::OutputReader.new(self, policy)
                end
            end
        end

        class InputPort < Syskit::InputPort
            def writer(policy = Hash.new)
                # The 'rescue' case is used only on first evaluation of the
                # block, when Roby instanciates it to check syntax.
                # The script blocks have to be re-instanciated for each
                # task they get applied on
                begin
                    component.resolve
                    super
                rescue Roby::Coordination::ResolvingUnboundObject
                    Syskit::Models::InputWriter.new(self, policy)
                end
            end
        end
    end
end

Roby::Coordination::TaskBase.include Syskit::Coordination::PortHandling

