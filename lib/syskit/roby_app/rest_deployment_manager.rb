module Syskit
    module RobyApp
        # Management of the deployments for the REST API
        class RESTDeploymentManager
            def initialize(conf)
                @conf = conf
                @new_deployments = Array.new
                @overrides = Hash.new
            end

            class Forbidden      < ArgumentError; end
            class NotFound       < ArgumentError; end
            class CannotOverride < Forbidden; end
            class UsedInOverride < CannotOverride; end

            # Change the configuration so that all tasks from the given
            # deployment are declared as unmanaged
            #
            # @param [Models::ConfiguredDeployment] configured_deployment
            # @return [Array,nil] the list of the IDs of the newly created
            #   deployments, or nil if the given ID does not match any registered
            #   deployment
            def make_unmanaged(id)
                overrides = []

                configured_deployment = find_registered_deployment_by_id(id)
                if !configured_deployment
                    if overriden?(id)
                        raise UsedInOverride, "#{id} is already overriden, cannot override it again"
                    else
                        raise NotFound, "#{id} is not a known deployment"
                    end
                elsif used_in_override?(configured_deployment)
                    raise UsedInOverride, "#{id} is already used in an override, cannot override it"
                end

                @conf.deregister_configured_deployment(configured_deployment)
                configured_deployment.each_orogen_deployed_task_context_model do |orogen_m|
                    task_m = Syskit::TaskContext.find_model_by_orogen(orogen_m.task_model)
                    overrides.concat(@conf.use_unmanaged_task(task_m => orogen_m.name))
                end
                @overrides[configured_deployment] = overrides
                overrides.map(&:object_id)

            rescue Exception => e
                overrides.each do |c|
                    @conf.deregister_configured_deployment(c)
                end
                if configured_deployment
                    @conf.register_configured_deployment(configured_deployment)
                end
                raise
            end

            # Clear all overrides and new deployments
            def clear
                @overrides.delete_if do |original, overriden_by|
                    overriden_by.delete_if do |c|
                        @conf.deregister_configured_deployment(c)
                        true
                    end
                    @conf.register_configured_deployment(original)
                    true
                end
                @new_deployments.delete_if do |c|
                    @conf.deregister_configured_deployment(c)
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
                @conf.each_configured_deployment.
                    find { |c| c.object_id == id }
            end

            # Finds a newly defined deployment by ID
            def find_new_deployment_by_id(id)
                @new_deployments.find { |c| c.object_id == id }
            end

            # Define a new deployment
            #
            # @return [Integer] the new deployment ID
            def use_deployment(*names, **run_options)
                c = @conf.use_deployment(*names, **run_options).first
                @new_deployments << c
                c.object_id
            end

            # Remove a deployment
            #
            # @return [Boolean] true if the deployment ID was valid, false otherwise
            def deregister_deployment(id)
                deployment = find_new_deployment_by_id(id)
                if !deployment
                    if find_registered_deployment_by_id(id)
                        raise Forbidden, "#{id} has not been registered through the REST API, cannot deregister it"
                    else
                        raise NotFound, "#{id} is not a known deployment"
                    end
                end

                @conf.deregister_configured_deployment(deployment)
                @new_deployments.delete(deployment)
            end

            # Remove overrides created by {#make_unmanaged}
            #
            # @return [Boolean] true if the deployment ID was valid, false otherwise
            def deregister_override(id)
                overriden_deployment = @overrides.keys.find { |c| c.object_id == id }
                if !overriden_deployment
                    deployment = find_registered_deployment_by_id(id)
                    if !deployment
                        raise NotFound, "#{id} is not an existing deployment"
                    else
                        raise Forbidden, "#{id} is not an overriden deployment, cannot deregister"
                    end
                end

                overrides = @overrides[overriden_deployment]
                overrides.delete_if do |c|
                    @conf.deregister_configured_deployment(c)
                    true
                end
                @overrides.delete(overriden_deployment)
                true
            end
        end
    end
end
