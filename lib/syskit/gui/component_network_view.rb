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
                    :remove_compositions => false,
                    :annotations => ['task_info', 'port_details'].to_set,
                    :zoom => 1
                ]
                @dataflow_options = Hash[
                    :title => 'Dataflow',
                    :id => 'dataflow',
                    :remove_compositions => false,
                    :annotations => ['task_info'].to_set,
                    :zoom => 1
                ]

                buttons = []
                buttons << Button.new("dataflow/show_compositions",
                                      :on_text => 'Show compositions',
                                      :off_text => 'Hide compositions',
                                      :state => !dataflow_options[:remove_compositions])
                buttons << Button.new("dataflow/show_loggers",
                                      :on_text => 'Show loggers',
                                      :off_text => 'Hide loggers',
                                      :state => !dataflow_options[:remove_loggers])
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
                options, render_options = Kernel.filter_options options, :method => :instanciate_model
                @task = begin send(options[:method], model, plan)
                        rescue Exception => e
                            if view_partial_plans? then
                                Roby.app.register_exception(e)
                                nil
                            else raise
                            end
                        end
                render_plan(render_options)
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

