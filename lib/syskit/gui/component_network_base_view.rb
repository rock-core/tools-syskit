module Syskit
    module GUI
        # Base functionality to display plans that contain component networks
        class ComponentNetworkBaseView < Qt::Object
            attr_reader :current_model
            attr_reader :page

            def initialize(page)
                super()
                @page = page
            end

            DATA_SERVICE_WITHOUT_NAMES_TEMPLATE = <<-EOD
            <table>
            <% services.each do |service_name, provided_services| %>
            <tr><td>
              <%= provided_services.map do |srv_model_name, srv_port_mappings|
                    if srv_port_mappings.empty? 
                        srv_model_name
                    else
                        "\#{srv_model_name}: \#{srv_port_mappings}"
                    end
                  end.join("</td></tr><tr><td>")
              %>
            </td></tr>
            <% end %>
            </table>
            EOD

            DATA_SERVICE_WITH_NAMES_TEMPLATE = <<-EOD
            <table>
            <% services.each do |service_name, provided_services| %>
            <tr><th><%= service_name %></th><td>
              <%= provided_services.map do |srv_model_name, srv_port_mappings|
                    if srv_port_mappings.empty? 
                        srv_model_name
                    else
                        "\#{srv_model_name}: \#{srv_port_mappings}"
                    end
                  end.join("</td></tr><tr><td>&nbsp;</td><td>")
              %>
            </td></tr>
            <% end %>
            </table>
            EOD

            def clear
            end

            def compute_system_network(model, main_plan = nil)
                main_plan ||= Roby::Plan.new
                main_plan.add(original_task = model.as_plan)
                base_task = original_task.as_service
                engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                engine.prepare
                engine.compute_system_network([base_task.task.planning_task])
                base_task.task
            ensure
                if engine && engine.work_plan.respond_to?(:commit_transaction)
                    engine.work_plan.commit_transaction
                    main_plan.remove_object(original_task)
                end
            end

            def instanciate_model(model, main_plan = nil)
                main_plan ||= Roby::Plan.new
                requirements = model.to_instance_requirements
                task = requirements.instanciate(
                    main_plan,
                    Syskit::DependencyInjectionContext.new)
                main_plan.add(task)
                task
            end

            def list_services(task)
                services = []
                task.model.each_data_service.sort_by(&:first).each do |service_name, service|
                    model_hierarchy = service.model.ancestors.
                        find_all do |m|
                        m.kind_of?(Syskit::Models::DataServiceModel) &&
                            m != Syskit::DataService &&
                            m != Syskit::Device &&
                            m != task.model
                    end

                    provided_services = []
                    model_hierarchy.each do |m|
                        port_mappings = service.port_mappings_for(m).dup
                        port_mappings.delete_if do |from, to|
                            from == to
                        end
                        provided_services << [m.name, port_mappings]
                    end
                    services << [service_name, provided_services]
                end
                services
            end

            def render_data_services(task, with_names = true)
                services = list_services(task)
                if services.empty?
                    html = ""
                else
                    if with_names
                        html = ERB.new(DATA_SERVICE_WITH_NAMES_TEMPLATE).result(binding)
                    else
                        html = ERB.new(DATA_SERVICE_WITHOUT_NAMES_TEMPLATE).result(binding)
                    end
                end

                page.push("Provided Services", html, :id => 'provided_services')
            end

            def find_definition_place(model)
                model.definition_location.find do |file, _, method|
                    return if method == :require || method == :using_task_library
                    Roby.app.app_file?(file)
                end
            end

            def render(model, options = Hash.new)
                if file = find_definition_place(model)
                    page.push(nil, "<p><b>Defined in</b> #{file[0]}:#{file[1]}</p>")
                end
                @current_model = model
            end

            signals 'updated()'
        end
    end
end


