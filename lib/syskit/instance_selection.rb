module Syskit
        # A representation of a selection matching a given requirement
        class InstanceSelection
            attr_reader :requirements

            attr_predicate :explicit?, true
            attr_accessor :selected_task
            attr_accessor :selected_services
            attr_accessor :port_mappings

            def initialize(requirements)
                @requirements = requirements
                @selected_services = Hash.new
                @port_mappings = Hash.new
            end

            def to_component
                if selected_task
                    return selected_task
                end
                raise ArgumentError, "#{self} has no selected component, cannot convert it"
            end

            # If this selection does not yet have an associated task,
            # instanciate one
            def instanciate(engine, context, options = Hash.new)
                requirements.narrow_model

                options[:task_arguments] ||= requirements.arguments
                if requirements.models.size == 1 && requirements.models.first.kind_of?(Class)
                    @selected_task = requirements.models.first.instanciate(engine, context, options)
                else
                    @selected_task = requirements.create_placeholder_task
                end

                selected_task.requirements.merge(self.requirements)
                selected_task
            rescue InstanciationError => e
                e.instanciation_chain << requirements
                raise
            end

            # Do an explicit service selection to match requirements in
            # +service_list+. New services get selected only if relevant
            # services are not already selected in +selected_services+
            def select_services_for(service_list)
                if selected_task
                    base_object = selected_task.model
                elsif (base_object = requirements.models.find { |m| m <= Component })
                    # Remove from service_list the services that are not
                    # provided by the component model we found. This is possible
                    # at this stage, as the model list can contain both
                    # a component model and a list of services.
                    service_list = service_list.find_all do |srv|
                        requirements.models.find { |m| m.fullfills?(srv) }
                    end
                end
                
                # At this stage, the selection only contains data services. We
                # therefore cannot do any explicit service selection and return.
                if !base_object
                    return
                end

                service_list.each do |srv|
                    matching_service =
                        selected_services.keys.find { |sel| sel.fullfills?(srv) }
                    if matching_service
                        selected_services[srv] = selected_services[matching_service]
                    else
                        selected_services.merge!(self.class.compute_service_selection(base_object, [srv], true))
                    end
                end
            end

            def self.select_service_by_name(task_model, service_name)
                if !(candidate = task_model.find_data_service(service_name))
                    # Look for child services. Watch out for ambiguities
                    candidates = task_model.each_data_service.find_all do |name, srv|
                        srv.name == service_name
                    end
                    if candidates.size > 1
                        raise AmbiguousServiceSelection.new(task_model, service_name, candidates.map(&:last))
                    elsif candidates.empty?
                        raise UnknownServiceName.new(task_model, service_name)
                    else
                        candidate = candidates.first.last
                    end
                end
                candidate
            end

            def self.compute_service_selection(task_model, required_services, user_call)
                result = Hash.new
                required_services.each do |required|
                    next if !required.kind_of?(Models::DataServiceModel)
                    candidate_services =
                        task_model.find_all_services_from_type(required)

                    if candidate_services.size > 1
                        throw :invalid_selection if !user_call
                        raise AmbiguousServiceSelection.new(task_model, required, candidate_services)
                    elsif candidate_services.empty?
                        throw :invalid_selection if !user_call
                        raise NoMatchingService.new(task_model, required)
                    end
                    result[required] = candidate_services.first
                end
                result
            end

            def self.from_object(object, requirements = InstanceRequirements.new, user_call = true)
                result = InstanceSelection.new(requirements.dup)
                required_model = requirements.models

                object_requirements = InstanceRequirements.new
                case object
                when InstanceRequirements
                    result.requirements.merge(object)
                    if object.service
                        required_model.each do |required|
                            result.selected_services[required] = object.service
                        end
                    end
                when InstanceSelection
                    result.selected_task = object.selected_task
                    result.selected_services = object.selected_services
                    result.port_mappings = object.port_mappings
                    result.requirements.merge(object.requirements)
                when BoundDataService
                    if !object.provided_service_model
                        raise InternalError, "#{object} has no provided service model"
                    end
                    required_model.each do |required|
                        result.selected_services[required] = object.provided_service_model
                    end
                    result.selected_task = object.task
                    object_requirements.require_model(object.task.model)
                    object_requirements.select_service(object.provided_service_model)
                when Models::BoundDataService
                    required_model.each do |required|
                        result.selected_services[required] = object
                    end
                    object_requirements.require_model(object.component_model)
                    object_requirements.select_service(object)
                when Models::DataServiceModel
                    object_requirements.require_model(object)
                when Component
                    result.selected_task = object
                    result.selected_services = compute_service_selection(object.model, required_model, user_call)
                    object_requirements.require_model(object.model)
                else
                    if object < Component
                        object_requirements.require_model(object)
                        result.selected_services = compute_service_selection(object, required_model, user_call)
                    else
                        throw :invalid_selection if !user_call
                        raise ArgumentError, "invalid selection #{object}: expected a device name, a task instance or a model"
                    end
                end

                result.requirements.merge(object_requirements)
                result
            end

            def each_fullfilled_model(&block)
                requirements.each_fullfilled_model(&block)
            end

            def fullfills?(set)
                requirements.fullfills?(set)
            end

            def to_s
                "#<#{self.class}: #{requirements} selected_task=#{selected_task} selected_services=#{selected_services}>"
            end

            def pretty_print(pp)
                pp.text "InstanceSelection"
                pp.breakable
                pp.text "Selected: "
                selected_task.pretty_print(pp)
                pp.breakable
                pp.text "Selected Services: "
                if !selected_services.empty?
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(selected_services) do |sel|
                            pp.text "#{sel[0]} => #{sel[1]}"
                        end
                    end
                end
                pp.breakable
                pp.text "For: "
                pp.nest(2) do
                    pp.breakable
                    requirements.pretty_print(pp)
                end
            end
        end
end
