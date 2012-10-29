module Orocos
    module RobyPlugin
	# Model used to create a placeholder task from a concrete task model,
	# when a mix of data services and task context model cannot yet be
	# mapped to an actual task context model yet
        module ComponentModelProxy
            module ClassExtension
                attr_accessor :proxied_data_services
            end

            def proxied_data_services
                self.model.proxied_data_services
            end
        end

        # Placeholders used in the plan to represent a data service that has not
        # been mapped to a task context yet
        class DataServiceProxy < TaskContext
            extend Model
	    include ComponentModelProxy

            abstract

            class << self
		# A made-up name describing this proxy
                attr_accessor :name
		# A made-up name describing this proxy
                attr_accessor :short_name
            end
            @name = "Orocos::RobyPlugin::DataServiceProxy"

            def to_s
                "placeholder for #{self.model.short_name}"
            end

            def self.new_submodel(name, models = [])
                Class.new(self) do
                    abstract
                    @name = name
                    @short_name = models.map(&:short_name).sort.join(",")
		    @proxied_data_services = models
                end
            end
        end

	# This method creates a task model that can be used to represent the
	# models listed in +models+ in a plan. The returned task model is
	# obviously abstract
        def self.placeholder_model_for(name, models)
	    task_model = models.find { |t| t < Roby::Task }

            # If all that is required is a proper task model, just return it
            if models.size == 1 && task_model
                return task_model
            end

            if task_model
                model = task_model.specialize("placeholder_model_for_" + models.map(&:short_name).join("_"))
                model.name = name
                model.abstract
                model.include ComponentModelProxy
                model.proxied_data_services = models.dup
		model.proxied_data_services.delete(task_model)
		model.fullfilled_model = [task_model, model.proxied_data_services, Hash.new]
            else
                model = DataServiceProxy.new_submodel(name, models)
		model.fullfilled_model = [Roby::Task, models, Hash.new]
            end

            orogen_spec = RobyPlugin.create_orogen_interface
            model.instance_variable_set(:@orogen_spec, orogen_spec)
            RobyPlugin.merge_orogen_interfaces(model.orogen_spec, models.map(&:orogen_spec))
            models.each do |m|
                if m.kind_of?(DataServiceModel)
                    model.provides m
                end
            end

            model
        end
    end
end
