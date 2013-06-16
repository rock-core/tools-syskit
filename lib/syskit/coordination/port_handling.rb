module Syskit
    module Coordination
        # Port access code for instance-level task objects
        module PortHandling
            def find_port(port_name)
                if model_port = model.find_port(port_name)
                    model_port.bind(self)
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
    end
end

Roby::Coordination::TaskBase.include Syskit::Coordination::PortHandling

