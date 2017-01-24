module Syskit
    module GUI
        # Base functionality to display plans that contain component networks
        class ComponentNetworkBaseView < Qt::Object
            # The last model given to {#render}
            attr_reader :current_model

            # The page on which the rendered HTML is pushed
            #
            # @return [Page]
            attr_reader :page

            # The last generated plan
            attr_reader :plan

            Button = MetaRuby::GUI::HTML::Button

            # Generate a list of buttons to show or hide annotations
            #
            # @param [String] namespace the button namespace, i.e. a string that
            #   is prefixed before the button ID. The final button ID is
            #   #{namespace}/annotations/#{annotation_name}
            # @param [Array<String>] the list of annotations
            # @param [Set<String>] the set of annotations that are initially shown
            def self.make_annotation_buttons(namespace, annotations, defaults)
                annotations.sort.map do |ann_name|
                    Button.new("#{namespace}/annotations/#{ann_name}",
                               on_text: "Show #{ann_name}",
                               off_text: "Hide #{ann_name}",
                               state: defaults.include?(ann_name))
                end
            end

            # Generate common list of buttons
            #
            # @param [String] namespace the button namespace, i.e. a string that
            #   is prefixed before the button ID. The final button ID are
            #   #{namespace}/#{button_name} (e.g. #{namespace}/zoom)
            def self.common_graph_buttons(namespace)
                [Button.new("#{namespace}/zoom", text: "Zoom +"),
                 Button.new("#{namespace}/unzoom", text: "Zoom -"),
                 Button.new("#{namespace}/save", text: "Save SVG")]
            end

            # Generate the list of buttons that allows to display or hide
            # task annotations as enumerated by {Graphviz.available_task_annotations}
            #
            # @param [String] namespace the button namespace, i.e. a string that
            #   is prefixed before the button ID. The final button ID is
            #   #{namespace}/annotations/#{annotation_name}
            # @param [Set<String>] the set of annotations that are initially shown
            #
            # @see Graphviz.available_task_annotations
            def self.task_annotation_buttons(namespace, defaults)
                make_annotation_buttons(namespace, Graphviz.available_task_annotations, defaults)
            end

            # Generate the list of buttons that allows to display or hide
            # graph annotations, as enumerated by
            # {Graphviz.available_graph_annotations}
            #
            # @param [String] namespace the button namespace, i.e. a string that
            #   is prefixed before the button ID. The final button ID is
            #   #{namespace}/annotations/#{annotation_name}
            # @param [Set<String>] the set of annotations that are initially shown
            #
            # @see Graphviz.available_graph_annotations
            def self.graph_annotation_buttons(namespace, defaults)
                make_annotation_buttons(namespace, Graphviz.available_graph_annotations, defaults)
            end

            def initialize(page)
                super()
                @page = page
            end

            # Enable this HTML renderer
            #
            # This is usually not called directly, it is used by
            # {MetaRuby::GUI::ModelBrowser}
            def enable
                connect(page, SIGNAL('buttonClicked(const QString&,bool)'), self, SLOT('buttonClicked(const QString&,bool)'))
            end

            # Disable this HTML renderer
            #
            # This is usually not called directly, it is used by
            # {MetaRuby::GUI::ModelBrowser}
            def disable
                disconnect(page, SIGNAL('buttonClicked(const QString&,bool)'), self, SLOT('buttonClicked(const QString&,bool)'))
            end

            # Template used in {#render_data_services} if the with_names argument is false
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

            # Template used in {#render_data_services} if the with_names argument is true
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

            # Compute the system network for a model
            #
            # @param [Model<Component>] model the model whose representation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def compute_system_network(model, main_plan = nil)
                main_plan ||= Roby::Plan.new
                main_plan.add(original_task = model.as_plan)
                base_task = original_task.as_service
                engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                engine.compute_system_network([base_task.task.planning_task])
                base_task.task
            ensure
                if engine && engine.work_plan.respond_to?(:commit_transaction)
                    engine.work_plan.commit_transaction
                    main_plan.remove_task(original_task)
                end
            end

            # Instanciate a model
            #
            # @param [Model<Component>] model the model whose instanciation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @param [Hash] options options to be passed to
            #   {Syskit::InstanceRequirements#instanciate}
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def instanciate_model(model, main_plan = nil, options = Hash.new)
                main_plan ||= Roby::Plan.new
                requirements = model.to_instance_requirements
                task = requirements.instanciate(
                    main_plan,
                    Syskit::DependencyInjectionContext.new,
                    options)
                main_plan.add(task)
                task
            end

            # List the services provided by a component
            #
            # @param [Component] task the component
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

            # Render the data services of task into HTML
            #
            # @param [Component] task the component
            # @param [Boolean] with_names whether the output should contain the
            #   service names or not
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

                page.push("Provided Services", html, id: 'provided_services')
            end

            # Find the file, line number and method name where a model was defined
            #
            # @param [Model<Component>] model
            # @return [(String,Integer,String),nil] the definition place or nil
            #   if one cannot be determined
            def self.find_definition_place(model)
                location = model.definition_location.find do |location|
                    return if location.label == 'require' || location.label == 'using_task_library'
                    Roby.app.app_file?(location.absolute_path)
                end
                if location
                    return location.absolute_path, location.lineno
                end
            end

            # Render the snippet that represents the definition place of a model
            #
            # @param [#push] the page on which the HTML should be pushed
            # @param [Model<Component>] the model
            # @param [Boolean] with_require whether a require '...' line
            #   should be rendered as well
            # @param definition_location the model's definition location. If
            #   nil, it will be determined by calling {.find_definition_place}
            # @param [String] format a format string (usable with {String#%}
            #   used to render the definition place in HTML
            def self.html_defined_in(page, model, with_require: true, definition_location: nil, format: "<b>Defined in</b> %s")
                path, lineno = *definition_location || find_definition_place(model)
                if path
                    path = Pathname.new(path)
                    path_link = page.link_to(path, "#{path}:#{lineno}", lineno: lineno)
                    page.push(nil, "<p>#{format % [path_link]}</p>")
                    if with_require
                        if req_base = $LOAD_PATH.find { |p| path.fnmatch?(File.join(p, "*")) }
                            req = path.relative_path_from(Pathname.new(req_base))
                            page.push(nil, "<code>require '#{req.sub_ext("")}'</code>")
                        end
                    end
                end
            end

            def render_require_section(model)
                if model.respond_to?(:definition_location)
                    ComponentNetworkBaseView.html_defined_in(page, model, with_require: true)
                end
            end

            def render(model, options = Hash.new)
                render_require_section(model)
                @current_model = model
            end

            # Save a SVG fragment to a file
            #
            # This basically saves the content of a fragment to a file. It does
            # not validate that the data passed to {Page#push} is actually SVG
            # content.
            #
            # @param [String] id the fragment id as given to {Page#push}
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

            # @api private
            #
            # Slot called when a HTML button is clicked by the user
            #
            # It handles the common component view buttons
            def buttonClicked(button_id, new_state)
                button_id =~ /\/(\w+)(.*)/
                namespace, button_id = $1, $2
                config = send("#{namespace}_options")
                case button_id
                when /\/show_compositions/
                    config[:remove_compositions] = !new_state
                when /\/show_all_ports/
                    config[:show_all_ports] = new_state
                when /\/show_logger/
                    if new_state
                        config[:excluded_models].delete(OroGen::Logger::Logger)
                    else
                        config[:excluded_models] << OroGen::Logger::Logger
                    end
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

            # Adds or updates a plan representation on the HTML page
            #
            # @param [String] kind either 'dataflow' or 'hierarchy'
            # @param [Roby::Plan] plan
            # @param [Boolean] interactive whether the display is going to be
            #   interactive
            def push_plan(kind, plan, interactive: true, **push_options)
                config = send("#{kind}_options").merge(push_options)
                if !interactive
                    config.delete(:buttons)
                end
                title = config.delete(:title)
                page.push_plan(title, config.delete(:mode) || kind, plan, config)
            end
        end
    end
end


