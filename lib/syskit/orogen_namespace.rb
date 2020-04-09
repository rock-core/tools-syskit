# frozen_string_literal: true

module Syskit
    # Implementation of the model access as available through the OroGen
    # toplevel constant
    #
    # Assuming a test project that has a test::Task component, one can
    # access it through OroGen.test.Task
    #
    # It replaces the now-deprecated access through constants
    # (OroGen::Test::Task)
    module OroGenNamespace
        class ProjectNamespace < BasicObject
            # The name of the underlying oroGen project
            attr_reader :project_name

            def initialize(name)
                @project_name = name
                @registered_objects = {}
                super()
            end

            NAMESPACE_PREFIX = /([^:]+)::/.freeze

            def register_syskit_model(model)
                orogen_name = model.orogen_model.name
                prefix = "#{project_name}::"
                unless orogen_name.start_with?(prefix)
                    ::Kernel.raise(
                        ::ArgumentError,
                        "#{model} does not seem to be part of the #{project_name} project"
                    )
                end

                remainder = orogen_name[prefix.size..-1]
                if (m = NAMESPACE_PREFIX.match(remainder))
                    namespace_name = m[1]
                    namespace = (
                        @registered_objects[namespace_name.to_sym] ||=
                            ProjectNamespace.new("#{prefix}#{namespace_name}")
                    )
                    namespace.register_syskit_model(model)
                else
                    @registered_objects[remainder.to_sym] = model
                end
            end

            def respond_to_missing?(m, _include_private = false)
                @registered_objects.key?(m)
            end

            def method_missing(m, *args, &block)
                if (model = @registered_objects[m])
                    return model if args.empty?

                    ::Kernel.raise(
                        ::ArgumentError,
                        "expected 0 arguments, got #{args.size}"
                    )
                end
                super
            rescue ::NoMethodError => e
                ::Kernel.raise e, "no task #{m} on #{project_name}, available tasks: "\
                    "#{@registered_objects.keys.map(&:to_s).sort.join(', ')}"
            end
        end

        class DeploymentNamespace < Module
            def initialize
                super
                @deployments = {}
                @registered_constants = []
            end

            def register_syskit_model(deployment_model)
                @deployments[deployment_model.orogen_model.name] = deployment_model
                if OroGen.syskit_model_constant_registration?
                    register_syskit_model_as_constant(deployment_model)
                end

                nil
            end

            def clear
                @registered_constants.delete_if do |name|
                    begin
                        ::Deployments.send(:remove_const, name)
                    rescue NameError # rubocop:disable Lint/SuppressedException
                    end
                    true
                end
                @deployments = {}
            end

            # @api private
            #
            # Registers the given syskit model on the class hierarchy, using
            # the
            # (camelized) orogen name as a basis
            #
            # If there is a constant clash, the model will not be registered
            # but its #name method will return the "right" value enclosed in <>
            #
            # @return [Boolean] true if the model could be registered and false
            #   otherwise
            def register_syskit_model_as_constant(model)
                orogen_model = model.orogen_model
                const_name = orogen_model.name.camelcase(:upper)
                ::Deployments.const_set(const_name, model)
                @registered_constants << const_name
            end

            def respond_to_missing?(name, _include_private = false)
                @deployments.key?(name.to_s)
            end

            def method_missing(name, *args, **kw)
                if (m = @deployments[name.to_s])
                    unless args.empty? && kw.empty?
                        raise ArgumentError,
                              "wrong number of arguments, given #{args.size} and #{kw.size} "\
                              "keyword arguments, expected 0"
                    end

                    return m
                end

                super
            rescue NoMethodError
                deployments_s = @deployments.keys.join(", ")
                raise NoMethodError.new(name),
                      "no deployment registered with the name '#{name}', "\
                      "available deployments are: #{deployments_s}"
            end
        end

        attr_predicate :syskit_model_constant_registration?, true
        attr_predicate :syskit_model_toplevel_constant_registration?, true

        def self.extend_object(m)
            super
            m.instance_variable_set :@registered_constants, Set.new
            m.clear
        end

        def clear
            @registered_constants.delete_if do |_root, namespace, name|
                begin
                    namespace.send(:remove_const, name)
                rescue NameError # rubocop:disable Lint/SuppressedException
                end
                true
            end
            @project_namespaces = {}
            @registered_models = {}
        end

        def project_name?(name)
            @project_namespaces.key?(name)
        end

        # Resolve the registered syskit model that has the given orogen name
        def syskit_model_by_orogen_name(name)
            unless (model = @registered_models[name])
                raise ArgumentError, "#{name} is not registered on #{self}"
            end

            model
        end

        def registered_model_name_prefix
            @registered_model_name_prefix ||= "#{name || to_s}."
        end

        def respond_to_missing?(m, _include_private = false)
            @project_namespaces.key?(m)
        end

        def method_missing(m, *args, &block)
            return super unless (project = @project_namespaces[m])

            unless args.empty?
                raise ArgumentError, "expected 0 arguments, got #{args.size}"
            end

            project
        rescue NoMethodError => e
            raise e, "#{e.message}, available OroGen projects: "\
                     "#{@project_namespaces.keys.map(&:to_s).join(', ')}"
        end

        def register_syskit_model(model)
            if syskit_model_constant_registration?
                register_syskit_model_as_constant(model)
            end

            project_name = model.orogen_model.name.split("::").first
            unless project_name
                raise ArgumentError, "cannot register a project with no name"
            end

            unless (project_ns = @project_namespaces[project_name.to_sym])
                project_ns = @project_namespaces[project_name.to_sym] =
                    ProjectNamespace.new(project_name)
            end

            project_ns.register_syskit_model(model)
            @registered_models[model.orogen_model.name] = model
            registered_model_name_prefix + model.orogen_model.name.split("::").join(".")
        end

        # @api private
        #
        # Translates an orogen task context model name into the syskit
        # equivalent
        #
        # @return [(String,String)] the namespace and class names
        def syskit_names_from_orogen_name(orogen_name)
            namespace, basename = orogen_name.split "::"
            [namespace.camelcase(:upper), basename.camelcase(:upper)]
        end

        # @api private
        #
        # Registers the given syskit model on the class hierarchy, using the
        # (camelized) orogen name as a basis
        #
        # If there is a constant clash, the model will not be registered but
        # its #name method will return the "right" value enclosed in <>
        #
        # @return [Boolean] true if the model could be registered and false
        # otherwise
        def register_syskit_model_as_constant(model)
            orogen_model = model.orogen_model

            namespace, basename = syskit_names_from_orogen_name(orogen_model.name)
            if syskit_model_toplevel_constant_registration?
                namespace_mod = OroGenNamespace.register_syskit_model_as_constant(
                    Object, namespace, basename, model
                )
                if namespace_mod
                    @registered_constants << [Object, namespace_mod, basename]
                end
            end
            namespace_mod = OroGenNamespace.register_syskit_model_as_constant(
                self, namespace, basename, model
            )
            @registered_constants << [self, namespace_mod, basename] if namespace_mod
        end

        def self.register_syskit_model_as_constant(mod, namespace, basename, model)
            namespace =
                if mod.const_defined_here?(namespace)
                    mod.const_get(namespace)
                else
                    mod.const_set(namespace, Module.new)
                end

            if namespace.const_defined_here?(basename)
                Syskit::TaskContext.warn(
                    "there is already a constant with the name" \
                    "#{namespace.name}::#{basename}, I am not registering the model" \
                    "for #{model.orogen_model.name} there"
                )
                false
            else
                namespace.const_set(basename, model)
                namespace
            end
        end
    end
end
