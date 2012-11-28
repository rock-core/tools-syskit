module Syskit
	# Model used to create a placeholder task from a concrete task model,
	# when a mix of data services and task context model cannot yet be
	# mapped to an actual task context model yet
        module PlaceholderTask
            module ClassExtension
                attr_accessor :proxied_data_services
            end

            def proxied_data_services
                self.model.proxied_data_services
            end
        end

        module Models::TaskContext
            # [Hash{Array<DataService> => Models::Task}] a cache of models
            # creates in #proxy_task_model
            attribute(:proxy_task_models) { Hash.new }

            # Clears all registered submodels, reimplemented from Models::Base
            #
            # In addition to removing registered submodels, it also clears the
            # cache for task model proxies
            def clear_submodels
                super
                proxy_task_models.clear
            end

            # Create a task model that can be used as a placeholder in a Roby
            # plan for this task model and the following service models.
            #
            # @see Syskit.proxy_task_model_for
            def proxy_task_model(service_models)
                service_models = service_models.to_set
                if task_model = proxy_task_models[service_models]
                    return task_model
                end

                name = "Syskit::PlaceholderTask<#{self.short_name},#{service_models.map(&:short_name).sort.join(",")}>"
                model = specialize(name)
                model.abstract
                model.include PlaceholderTask
                model.proxied_data_services = service_models.dup
		model.fullfilled_model = [self, model.proxied_data_services, Hash.new]

                Syskit::Models.merge_orogen_task_context_models(model.orogen_model, service_models.map(&:orogen_model))
                service_models.each do |m|
                    model.provides m
                end
                proxy_task_models[service_models] = model
                model
            end
        end

	# This method creates a task model that can be used to represent the
	# models listed in +models+ in a plan. The returned task model is
	# obviously abstract
        def self.proxy_task_model_for(models)
	    task_models, service_models = models.partition { |t| t < Component }
            if task_models.size > 1
                raise ArgumentError, "cannot create a proxy for multiple component models at the same time"
            end
            task_model = task_models.first || TaskContext

            # If all that is required is a proper task model, just return it
            if service_models.empty?
                return task_model
            end

            task_model.proxy_task_model(service_models)
        end
end
