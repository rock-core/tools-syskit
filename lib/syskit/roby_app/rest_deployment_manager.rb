# frozen_string_literal: true

module Syskit
    module RobyApp
        # Management of the deployments for the REST API
        class RESTDeploymentManager
            def initialize(conf)
                @conf = conf
                @deployment_group = conf.deployment_group
                @new_deployments = []
                @overrides = {}
            end

            class Forbidden      < ArgumentError; end
            class NotFound       < ArgumentError; end
            class CannotOverride < Forbidden; end
            class AlreadyOverriden < CannotOverride; end
            class UsedInOverride < CannotOverride; end
            class NotOverriden < Forbidden; end
            class NotOrogen < Forbidden; end
            class NotCreatedHere < Forbidden; end

            # Change the configuration so that all tasks from the given
            # deployment are declared as unmanaged
            #
            # @param [Models::ConfiguredDeployment] configured_deployment
            # @return [Array,nil] the list of the IDs of the newly created
            #   deployments, or nil if the given ID does not match any registered
            #   deployment
            def make_unmanaged(id)
                # Define early to simplify the rescue clause
                overrides = []

                configured_deployment = find_registered_deployment_by_id(id)
                if !configured_deployment
                    if overriden?(id)
                        raise AlreadyOverriden, "#{id} is already overriden, cannot override it again"
                    else
                        raise NotFound, "#{id} is not a known deployment"
                    end
                elsif used_in_override?(configured_deployment)
                    raise UsedInOverride, "#{id} is already used in an override, cannot override it"
                end

                @deployment_group.deregister_configured_deployment(configured_deployment)
                configured_deployment.each_orogen_deployed_task_context_model do |orogen_m|
                    task_m = Syskit::TaskContext.find_model_by_orogen(orogen_m.task_model)
                    @conf.process_server_config_for("unmanaged_tasks")
                    new_deployments = @deployment_group.use_unmanaged_task(
                        { task_m => orogen_m.name },
                        process_managers: @conf
                    )
                    # Update overrides at each iteration (instead of using a functional
                    # construct) so that the rescue clause can undo the overrides that
                    # have already been done when an exception is raised
                    overrides.concat(new_deployments)
                end
                @overrides[configured_deployment] = overrides
                overrides.map(&:object_id)
            rescue Exception
                overrides.each do |c|
                    @deployment_group.deregister_configured_deployment(c)
                end
                if configured_deployment
                    @deployment_group.register_configured_deployment(configured_deployment)
                end
                raise
            end

            # Clear all overrides and new deployments
            def clear
                @overrides.delete_if do |original, overriden_by|
                    overriden_by.delete_if do |c|
                        @deployment_group.deregister_configured_deployment(c)
                        true
                    end
                    @deployment_group.register_configured_deployment(original)
                    true
                end
                @new_deployments.delete_if do |c|
                    @deployment_group.deregister_configured_deployment(c)
                    true
                end
            end

            # Enumerate the deployments that are being overriden
            def each_overriden_deployment(&block)
                @overrides.each_key(&block)
            end

            # Whether this deployment has been created by this manager
            def created_here?(deployment)
                @new_deployments.include?(deployment) ||
                    used_in_override?(deployment)
            end

            # Whether the given deployment is already overriden
            def overriden?(id)
                @overrides.keys.any? { |c| c.object_id == id }
            end

            # Whether the given deployment is used as override
            def used_in_override?(deployment)
                @overrides.each_value.any? do |overrides|
                    overrides.include?(deployment)
                end
            end

            # Finds a registered deployment by ID
            def find_registered_deployment_by_id(id)
                @deployment_group.each_configured_deployment
                                 .find { |c| c.object_id == id }
            end

            # Finds an overriden deployment by ID
            def find_overriden_deployment_by_id(id)
                @overrides.keys.find { |c| c.object_id == id }
            end

            # Finds a newly defined deployment by ID
            def find_new_deployment_by_id(id)
                @new_deployments.find { |c| c.object_id == id }
            end

            # Define a new deployment
            #
            # @return [Integer] the new deployment ID
            def use_deployment(*names, **run_options)
                c = @deployment_group.use_deployment(*names, **run_options).first
                @new_deployments << c
                c.object_id
            end

            # Remove a deployment
            #
            # @return [Boolean] true if the deployment ID was valid, false otherwise
            def deregister_deployment(id)
                deployment = find_new_deployment_by_id(id)
                unless deployment
                    if deployment = find_registered_deployment_by_id(id)
                        if used_in_override?(deployment)
                            raise UsedInOverride, "#{id} has been created for the purpose of an override, cannot deregister it"
                        else
                            raise NotCreatedHere, "#{id} has not been registered through the REST API, cannot deregister it"
                        end
                    else
                        raise NotFound, "#{id} is not a known deployment"
                    end
                end

                @deployment_group.deregister_configured_deployment(deployment)
                @new_deployments.delete(deployment)
            end

            # Remove overrides created by {#make_unmanaged}
            #
            # @return [Boolean] true if the deployment ID was valid, false otherwise
            def deregister_override(id)
                overriden_deployment = @overrides.keys.find { |c| c.object_id == id }
                unless overriden_deployment
                    deployment = find_registered_deployment_by_id(id)
                    if !deployment
                        raise NotFound, "#{id} is not an existing deployment"
                    else
                        raise NotOverriden, "#{id} is not an overriden deployment, cannot deregister"
                    end
                end

                overrides = @overrides[overriden_deployment]
                overrides.delete_if do |c|
                    @deployment_group.deregister_configured_deployment(c)
                    true
                end
                @overrides.delete(overriden_deployment)
                true
            end

            # Whether the given deployment is an oroGen deployment
            def orogen_deployment?(deployment)
                manager = @conf.process_server_config_for(deployment.process_server_name)
                manager.client.kind_of?(Syskit::RobyApp::RemoteProcesses::Client)
            end

            # Returns the command line needed to start the given deployment with the given spawn options
            #
            # The returned command line assumes that the Syskit process runs on
            # the machine where it will be executed
            def command_line(id, tracing: false,
                name_service_ip: "localhost",
                working_directory: @conf.app.log_dir,
                loader: @conf.app.default_pkgconfig_loader)

                deployment = find_registered_deployment_by_id(id) ||
                    find_overriden_deployment_by_id(id)
                if !deployment
                    raise NotFound, "#{id} is not a known deployment"
                elsif !orogen_deployment?(deployment)
                    raise NotOrogen, "#{id} is not an oroGen deployment, cannot generate a command line"
                end

                deployment.command_line(
                    working_directory: working_directory,
                    tracing: tracing,
                    name_service_ip: name_service_ip,
                    loader: loader
                )
            end
        end
    end
end
