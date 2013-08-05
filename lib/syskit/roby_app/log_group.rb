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
                @types = Set.new
                @names = Set.new
                @enabled = enabled
            end

            attr_reader :deployments
            attr_reader :tasks
            attr_reader :ports
            attr_reader :types
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

            # Tests if this group matches the given port
            #
            # @param [Syskit::Deployment] the deployment that runs the task of
            #   which {port} is a port
            # @param [Syskit::OutputPort] the port that is being tested
            # @return [Boolean]
            def matches_port?(deployment, port)
                if ports.any? { |model, port_name| port.name == port_name && port.component.fullfills?(model) }
                    true
                elsif tasks.include?(port.component.model)
                    true
                elsif deployments.include?(deployment.model)
                    true
                elsif types.include?(port.type)
                    true
                else
                    names.any? do |n|
                        n === port.type.name ||
                        n === port.component.orocos_name ||
                        n === port.name ||
                        n === "#{port.component.orocos_name}.#{port.name}"
                    end
                end
            end
        end
    end
end


