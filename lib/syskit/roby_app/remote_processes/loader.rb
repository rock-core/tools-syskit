module Orocos
    module RemoteProcesses
        # A loader object that allows to load models from a remote process
        # server
        class Loader < OroGen::Loaders::Base
            attr_reader :client

            attr_reader :available_projects
            attr_reader :available_deployments
            attr_reader :available_typekits

            def initialize(client, root_loader = self)
                @client = client
                @available_projects,
                    @available_deployments,
                    @available_typekits = client.info
                super(root_loader)
            end

            # Returns the textual representation of a project model
            #
            # @param [String] the project name
            # @raise [OroGen::NotFound] if there is no project with that
            #   name.
            # @return [(String,String)] the model as text, as well as a path to
            #   the model file (or nil if there is no such file)
            def project_model_text_from_name(name)
                if text = available_projects[name]
                    return text
                else
                    raise OroGen::ProjectNotFound, "#{client} has no project called #{name}, available projects: #{available_projects.keys.sort.join(", ")}"
                end
            end

            # Returns the textual representation of a typekit
            #
            # @param [String] the typekit name
            # @raise [OroGen::NotFound] if there is no typekit with that name
            # @return [(String,String)] the typekit registry as XML and the
            #   typekit's typelist
            def typekit_model_text_from_name(name)
                if text = available_typekits[name]
                    return *text
                else 
                    raise OroGen::TypekitNotFound, "#{client} has no typekit called #{name}"
                end
            end

            # Tests if a project with that name exists
            #
            # @param [String] name the project name
            # @return [Boolean]
            def has_project?(name)
                available_projects.has_key?(name)
            end

            # Tests if a typekit with that name exists
            #
            # @param [String] name the typekit name
            # @return [Boolean]
            def has_typekit?(name)
                available_typekits.has_key?(name)
            end

            # Tests if a deployment with that name exists
            #
            # @param [String] name the deployment name
            # @return [Boolean]
            def has_deployment?(name)
                available_deployments.has_key?(name)
            end
            # Returns the project that defines the given deployment
            #
            # @param [String] deployment_name the deployment we are looking for
            # @return [String,nil]
            def find_project_from_deployment_name(name)
                if project_name = available_deployments[name]
                    return project_name
                else 
                    raise OroGen::DeploymentModelNotFound, "#{client} has no deployment called #{name}"
                end
            end

            def each_available_project_name(&block)
                return available_projects.each_key(&block)
            end
        end
    end
end

