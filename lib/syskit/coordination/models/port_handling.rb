module Syskit
    module Coordination
        module Models
            # Port access code for model-level task objects
            module PortHandling
                def find_port(port_name)
                    if !model.respond_to?(:find_port)
                        raise ArgumentError, "cannot access ports on #{model}: it is not a component model"
                    elsif port = model.find_port(port_name)
                        port.attach(self)
                    end
                end

                def bind(task)
                    task
                end

                def self_port_to_component_port(port)
                    model.self_port_to_component_port(port)
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
end

Roby::Coordination::Models::Task.include Syskit::Coordination::Models::PortHandling

