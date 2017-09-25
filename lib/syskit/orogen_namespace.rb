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
                @registered_models = ::Hash.new
                super()
            end

            def register_syskit_model(model)
                orogen_name = model.orogen_model.name
                prefix = "#{project_name}::"
                if !orogen_name.start_with?(prefix)
                    ::Kernel.raise ::ArgumentError, "#{model} does not seem to be part of the #{project_name} project"
                end

                @registered_models[orogen_name[prefix.size..-1].to_sym] = model
            end

            def respond_to_missing?(m, include_private = false)
                @registered_models.has_key?(m)
            end

            def method_missing(m, *args, &block)
                if model = @registered_models[m]
                    if args.empty?
                        return model
                    else
                        raise ArgumentError, "expected 0 arguments, got #{args.size}"
                    end
                end
                super
            end
        end

        attr_predicate :syskit_model_constant_registration?, true
        attr_predicate :syskit_model_toplevel_constant_registration?, true

        def self.extend_object(m)
            super
            m.instance_variable_set :@project_namespaces, Hash.new
            m.instance_variable_set :@registered_models, Hash.new
        end

        def clear
            @project_namespaces = Hash.new
            @registered_models = Hash.new
        end

        # Resolve the registered syskit model that has the given orogen name
        def syskit_model_by_orogen_name(name)
            if model = @registered_models[name]
                model
            else raise ArgumentError, "#{name} is not registered on #{self}"
            end
        end

        def respond_to_missing?(m, include_private = false)
            @project_namespaces.has_key?(m)
        end

        def method_missing(m, *args, &block)
            if project = @project_namespaces[m]
                if args.empty?
                    return project
                else
                    raise ArgumentError, "expected 0 arguments, got #{args.size}"
                end
            end
            super
        end

        def register_syskit_model(model)
            if syskit_model_constant_registration?
                register_syskit_model_as_constant(model)
            end

            project_name = model.orogen_model.project.name
            if !project_name
                raise ArgumentError, "cannot register a project with no name"
            end
            project_ns =
                (@project_namespaces[project_name.to_sym] ||= ProjectNamespace.new(project_name))

            project_ns.register_syskit_model(model)
            @registered_models[model.orogen_model.name] = model
        end

        # @api private
        #
        # Translates an orogen task context model name into the syskit
        # equivalent
        #
        # @return [(String,String)] the namespace and class names
        def syskit_names_from_orogen_name(orogen_name)
            namespace, basename = orogen_name.split '::'
            return namespace.camelcase(:upper), basename.camelcase(:upper)
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
                OroGenNamespace.register_syskit_model_as_constant(
                    Object, namespace, basename, model)
            end
            OroGenNamespace.register_syskit_model_as_constant(
                self, namespace, basename, model)
        end

        def self.register_syskit_model_as_constant(mod, namespace, basename, model)
            namespace =
                if mod.const_defined_here?(namespace)
                    mod.const_get(namespace)
                else 
                    mod.const_set(namespace, Module.new)
                end

            if namespace.const_defined_here?(basename)
                warn "there is already a constant with the name #{namespace.name}::#{basename}, I am not registering the model for #{orogen_model.name} there"
                false
            else
                namespace.const_set(basename, model)
                true
            end
        end

    end
end
