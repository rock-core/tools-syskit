require 'metaruby/gui/html/button'
require 'syskit/gui/component_network_base_view'
module Syskit
    module GUI
        # Generic component network visualization
        #
        # It displays the task hierarchy as well as the dataflow network
        class ComponentNetworkView < ComponentNetworkBaseView
            attr_predicate :view_partial_plans?, true
            attr_reader :dataflow_options
            attr_reader :hierarchy_options
            attr_reader :plan
            attr_reader :task

            def initialize(page)
                super
                @view_partial_plans = true
                @plan = Roby::Plan.new

                @hierarchy_options = Hash[
                    :title => 'Task Dependency Hierarchy',
                    :id => 'hierarchy',
                    :remove_logger => true,
                    :remove_compositions => true,
                    :annotations => ['task_info', 'port_details'].to_set,
                    :zoom => 1
                ]
                @dataflow_options = Hash[
                    :title => 'Dataflow',
                    :id => 'dataflow',
                    :remove_logger => true,
                    :remove_compositions => true,
                    :annotations => ['task_info'].to_set,
                    :excluded_models => Set.new,
                    :zoom => 1
                ]

                buttons = []
                buttons << Button.new("dataflow/show_compositions",
                                      :on_text => 'Show compositions',
                                      :off_text => 'Hide compositions',
                                      :state => !dataflow_options[:remove_compositions])
                buttons << Button.new("dataflow/show_all_ports",
                                      :on_text => 'Show all ports',
                                      :off_text => 'Hide unused ports',
                                      :state => !dataflow_options[:show_all_ports])

                if defined? ::Logger::Logger
                    dataflow_options[:excluded_models] << ::Logger::Logger
                    buttons << Button.new("dataflow/show_loggers",
                                          :on_text => 'Show loggers',
                                          :off_text => 'Hide loggers',
                                          :state => false)
                end

                buttons.concat(self.class.common_graph_buttons('dataflow'))
                buttons.concat(self.class.task_annotation_buttons('dataflow', dataflow_options[:annotations]))
                buttons.concat(self.class.graph_annotation_buttons('dataflow', dataflow_options[:annotations]))
                dataflow_options[:buttons] = buttons

                buttons = []
                buttons.concat(self.class.common_graph_buttons('hierarchy'))
                hierarchy_options[:buttons] = buttons
            end

            def render(model, options = Hash.new)
                super

                plan.clear
                options, render_options = Kernel.filter_options options,
                    :method => :instanciate_model, :name => nil, :show_requirements => false, :instanciate_options => Hash.new

                if options[:show_requirements]
                    html = ModelViews.render_instance_requirements(page,
                            model.to_instance_requirements,
                            :resolve_dependency_injection => true).join("\n")
                    page.push("Resolved Requirements", "<pre>#{html}</pre>")
                end

                @task = begin
                            if options[:method] == :compute_system_network
                                compute_system_network(model, plan)
                            else instanciate_model(model, plan, options[:instanciate_options])
                            end
                        rescue Exception => e
                            if view_partial_plans? then
                                Roby.app.register_exception(e)
                                nil
                            else raise
                            end
                        end

                specific_options, render_options = Kernel.filter_options render_options,
                    :dataflow => Hash.new, :hierarchy => Hash.new
                hierarchy_options = render_options.merge(specific_options[:hierarchy])
                hierarchy_options = process_options('hierarchy', model, hierarchy_options)
                dataflow_options = render_options.merge(specific_options[:dataflow])
                dataflow_options = process_options('dataflow', model, dataflow_options)

                render_plan(:hierarchy => hierarchy_options,
                            :dataflow => dataflow_options)
            end

            def process_options(kind, model, options)
                options = Kernel.normalize_options options

                name = options[:name] || model.object_id.to_s
                if options[:id]
                    options[:id] = options[:id] % "#{kind}-#{name}"
                end

                if externals = options.delete(:external_objects)
                    options[:external_objects] = externals % "#{kind}-#{name}"
                end
                options
            end

            def render_plan(options = Hash.new)
                all_annotations = Syskit::Graphviz.available_annotations.to_set

                specific_options, options = Kernel.filter_options options,
                    :dataflow => Hash.new, :hierarchy => Hash.new

                hierarchy_options = options.merge(specific_options[:hierarchy])
                push_plan('hierarchy', plan, hierarchy_options)
                dataflow_options = Hash[:annotations => all_annotations].
                    merge(options).merge(specific_options[:dataflow])
                push_plan('dataflow', plan, dataflow_options)
                emit updated
            end
        end
    end
end

