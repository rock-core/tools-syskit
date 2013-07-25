module Syskit
    module GUI
        # Base functionality to display plans that contain component networks
        class ComponentNetworkBaseView < Qt::Object
            attr_reader :current_model
            attr_reader :page
            # The last generated plan
            attr_reader :plan

            Button = MetaRuby::GUI::HTML::Button

            def self.make_annotation_buttons(namespace, annotations, defaults)
                annotations.sort.map do |ann_name|
                    Button.new("#{namespace}/annotations/#{ann_name}",
                               :on_text => "Show #{ann_name}",
                               :off_text => "Hide #{ann_name}",
                               :state => defaults.include?(ann_name))
                end
            end

            def self.common_graph_buttons(namespace)
                [Button.new("#{namespace}/zoom", :text => "Zoom +"),
                 Button.new("#{namespace}/unzoom", :text => "Zoom -"),
                 Button.new("#{namespace}/save", :text => "Save SVG")]
            end

            def self.task_annotation_buttons(namespace, defaults)
                make_annotation_buttons(namespace, Graphviz.available_task_annotations, defaults)
            end

            def self.graph_annotation_buttons(namespace, defaults)
                make_annotation_buttons(namespace, Graphviz.available_graph_annotations, defaults)
            end

            def initialize(page)
                super()
                @page = page
            end

            def enable
                connect(page, SIGNAL('buttonClicked(const QString&,bool)'), self, SLOT('buttonClicked(const QString&,bool)'))
            end

            def disable
                disconnect(page, SIGNAL('buttonClicked(const QString&,bool)'), self, SLOT('buttonClicked(const QString&,bool)'))
            end

            DATA_SERVICE_WITHOUT_NAMES_TEMPLATE = <<-EOD
            <table>
            <% services.each do |service_name, provided_services| %>
            <tr><td>
              <%= provided_services.map do |srv_model, srv_port_mappings|
                    if srv_port_mappings.empty? 
                        page.link_to(srv_model)
                    else
                        "\#{page.link_to(srv_model)}: \#{srv_port_mappings}"
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
              <%= provided_services.map do |srv_model, srv_port_mappings|
                    if srv_port_mappings.empty? 
                        page.link_to(srv_model)
                    else
                        "\#{page.link_to(srv_model)}: \#{srv_port_mappings}"
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
                        provided_services << [m, port_mappings]
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

            def self.find_definition_place(model)
                model.definition_location.find do |file, _, method|
                    return if method == :require || method == :using_task_library
                    Roby.app.app_file?(file)
                end
            end

            def render(model, options = Hash.new)
                if model.respond_to?(:definition_location)
                    if file = ComponentNetworkBaseView.find_definition_place(model)
                        page.push(nil, "<p><b>Defined in</b> #{file[0]}:#{file[1]}</p>")
                        if req_base = $LOAD_PATH.find { |p| File.fnmatch?(File.join(p, "*") , file[0]) }
                            req = Pathname.new(file[0]).relative_path_from(Pathname.new(req_base))
                            page.push(nil, "<code>require '#{req.sub_ext("")}'</code>")
                        end
                    end
                end
                @current_model = model
            end

            def save_svg(id)
                page.fragments.each do |f|
                    if f.id == id
                        file_name = Qt::FileDialog::getSaveFileName @parent, 
                            "Save #{id} as SVG", ".", "SVG (*.svg)"
                        if file_name
                            File.open(file_name,"w") do |file|
                                file.write f.html
                            end
                        end
                    end
                end
            end

            def buttonClicked(button_id, new_state)
                button_id =~ /\/(\w+)(.*)/
                namespace, button_id = $1, $2
                config = send("#{namespace}_options")
                case button_id
                when /\/show_compositions/
                    config[:remove_compositions] = !new_state
                when /\/zoom/
                    config[:zoom] += 0.1
                when /\/unzoom/
                    if config[:zoom] > 0.1
                        config[:zoom] -= 0.1
                    end
                when /\/save/
                    save_svg namespace
                when  /\/annotations\/(\w+)/
                    ann_name = $1
                    if new_state then config[:annotations] << ann_name
                    else config[:annotations].delete(ann_name)
                    end
                end
                push_plan(namespace, plan)
                emit updated
            end
            slots 'buttonClicked(const QString&,bool)'

            signals 'updated()'

            def push_plan(id, plan, options = Hash.new)
                options, push_options = Kernel.filter_options options, :interactive => true
                config = send("#{id}_options").dup
                if !options[:interactive]
                    config.delete(:buttons)
                end
                title = config.delete(:title)
                page.push_plan(title, id, plan, config.merge(push_options))
            end
        end
    end
end


