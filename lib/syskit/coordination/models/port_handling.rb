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
                    MetaRuby::DSLs.find_through_method_missing(self, m, args, "port") ||
                        super
                end
            end
        end
    end
end

Roby::Coordination::Models::Task.include Syskit::Coordination::Models::PortHandling

