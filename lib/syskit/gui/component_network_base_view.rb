require 'syskit/gui/stacked_display'

module Syskit
    module GUI
        # Base functionality to display plans that contain component networks
        class ComponentNetworkBaseView < StackedDisplay
            attr_reader :current_model

            def instanciate_model(model)
                main_plan = Roby::Plan.new
                requirements = model.to_instance_requirements
                task = requirements.instanciate(
                    main_plan,
                    Syskit::DependencyInjectionContext.new)
                main_plan.add(task)
                task
            end

            def render_data_services(task)
                services = []
                task.model.each_data_service.sort_by(&:first).each do |service_name, service|
                    model_hierarchy = service.model.ancestors.
                        find_all do |m|
                        m.kind_of?(Syskit::Models::DataServiceModel) &&
                            m != Syskit::DataService &&
                            m != Syskit::Device &&
                            m != task.model
                    end

                    services << service_name
                    model_hierarchy.each do |m|
                        port_mappings = service.port_mappings_for(m).dup
                        port_mappings.delete_if do |from, to|
                            from == to
                        end
                        model_name = m.short_name.gsub("DataServices::", "")
                        if !port_mappings.empty?
                            services << "    #{model_name} with port mappings #{port_mappings}"
                        else
                            services << "    #{model_name}"
                        end
                    end
                end
                label = Qt::Label.new(services.join("\n"), self)
                label.background_role = Qt::Palette::NoRole
                push("Provided Services", label)
            end

            def render(model)
                clear
                @current_model = model
            end
        end
    end
end


