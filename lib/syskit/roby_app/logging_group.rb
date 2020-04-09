# frozen_string_literal: true

module Syskit
    module RobyApp
        # Representation of a group of ports
        #
        # This is used to configure which ports should or should not be
        # configured. The documentation of {LoggingConfiguration} provides usage
        # information.
        class LoggingGroup
            # @param [Boolean] enabled the group's initial state
            def initialize(enabled = true)
                @deployments = Set.new
                @tasks = Set.new
                @ports = Set.new
                @types = Set.new
                @name_set = Set.new
                @name_matchers = Set.new
                @enabled = enabled
            end

            # @!method enabled?
            # @!method enabled=(flag)
            #
            # Controls whether the ports matching this group should be logged
            # (enabled? == true) or not. See {LoggingConfiguration} for the
            # logging behaviour when a port is matched by multiple groups
            attr_predicate :enabled?, true

            # Set of deployment models whose ports should match
            #
            # @return [Set<Models::Deployment>]
            attr_reader :deployments

            # Set of task models whose ports should match
            #
            # @return [Set<Models::TaskContext>]
            attr_reader :tasks

            # Set of port models whose ports should match
            #
            # @return [Set<Models::Port>]
            attr_reader :ports

            # Set of types that should match
            #
            # @return [Set<Typelib::Type>]
            attr_reader :types

            # Set of names that are matched against the deployment (process)
            # name, port name, task name and type name
            #
            # @return [Set<String>]
            attr_reader :name_set

            # Set of objects that can match names. They are matched against the
            # deployment (process) name, port name, task name and type name
            #
            # @return [Set<#===>]
            attr_reader :name_matchers

            # Adds an object to this logging group
            #
            # @overload add(model)
            #   @param [DataService,Models::TaskContext] model match any task
            #     which either has this service, or is a subclass of this task
            #     context
            #
            # @overload add(deployment)
            #   @param [Models::Deployment] deployment match any task
            #     which is supported by this deployment
            #
            # @overload add(port)
            #   @param [Models::Port] model match any port matching this model
            #
            # @overload add(name)
            #   @param [String,Regexp,#===] name match any object (deployment, task, port or
            #     type) whose name matches this.
            #
            def add(object)
                case object
                when Class
                    if object < Syskit::TaskContext
                        tasks << object
                    elsif object < Syskit::Deployment
                        deployments << object
                    elsif object < Typelib::Type
                        types << object
                    else raise ArgumentError, "unexpected model type #{object}"
                    end
                when Models::Port
                    ports << object
                when String
                    name_set << object
                else
                    # Verify that the object can match strings
                    begin
                        object === "a test string"
                    rescue Exception => e
                        raise ArgumentError, "expected given object to match strings with #=== but it raised #{e}"
                    end
                    name_matchers << object
                end
            end

            # Tests whether the given name is matched by this group
            #
            # @param [String] name
            def matches_name?(name)
                name_set.include?(name) ||
                    name_matchers.any? { |m| m === name }
            end

            # Tests whether the given deployment is matched by this group
            #
            # @param [Deployment] deployment the deployment task
            def matches_deployment?(deployment)
                deployments.include?(deployment.model) ||
                    matches_name?(deployment.model.deployment_name)
            end

            # Tests whether the given type is matched by this group
            def matches_type?(type)
                types.include?(type) ||
                    matches_name?(type.name)
            end

            # Tests whether the given task is matched by this group
            #
            # @param [TaskContext] task
            def matches_task?(task)
                if tasks.include?(task.model)
                    true
                elsif tasks.any? { |t| task.model.fullfills?(t) }
                    true
                elsif matches_name?(task.orocos_name)
                    true
                elsif (deployment = task.execution_agent) && matches_deployment?(deployment)
                    true
                end
            end

            # Tests if this group matches the given port
            #
            # @param [Syskit::OutputPort] the port that is being tested
            # @return [Boolean]
            def matches_port?(port)
                if ports.include?(port.model)
                    true
                elsif ports.any? { |p| p.name == port.name && port.component.model.fullfills?(p.component_model) }
                    true
                elsif matches_name?(port.name)
                    true
                elsif matches_task?(port.component)
                    true
                elsif matches_type?(port.type)
                    true
                end
            end
        end
    end
end
