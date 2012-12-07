module Syskit
    module RobyApp
        # Representation of a set of ports to be logged
        #
        # It is used in Configuration to allow to enable/disable logging for
        # parts of the system easily
        class LogGroup
            def load(&block)
                instance_eval(&block)
            end

            def initialize(enabled = true)
                @deployments = Set.new
                @tasks = Set.new
                @ports = Set.new
                @names = Set.new
                @enabled = enabled
            end

            attr_reader :deployments
            attr_reader :tasks
            attr_reader :ports
            attr_reader :names

            attr_predicate :enabled? , true

            # Adds +object+ to this logging group
            #
            # +object+ can be
            # * a deployment model, in which case no task  in this deployment
            #   will be logged
            # * a task model, in which case no port of any task of this type
            #   will be logged
            # * a [task_model, port_name] pair
            # * a string. It can then either be a task name, a port name or a type
            #   name
            def add(object, subname = nil)
                if object.kind_of?(Class) && object < Syskit::DataService
                    if subname
                        ports << [object, subname]
                    else
                        tasks << object
                    end
                elsif object.kind_of?(Class) && object < Syskit::Deployment
                    deployments << object
                else
                    names << object.to_str
                end
            end

            def matches_deployment?(deployment)
                if deployments.include?(deployment.model)
                    true
                elsif names.include?(deployment.name)
                    true
                else
                    false
                end
            end

            def matches_port?(deployment, task_model, port)
                if ports.any? { |model, port_name| port.name == port_name && task_model.fullfills?(model) }
                    true
                elsif tasks.include?(task_model)
                    true
                elsif deployments.include?(deployment.model)
                    true
                else
                    names.include?(port.type_name) ||
                        names.include?(port.task.name) ||
                        names.include?(port.name) ||
                        names.include?("#{port.task.name}.#{port.name}")
                end
            end
        end
    end
end


