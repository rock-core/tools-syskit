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
                    :id => 'hierarchy',
                    :remove_compositions => false,
                    :annotations => ['task_info', 'port_details'].to_set
                ]
                @dataflow_options = Hash[
                    :id => 'dataflow',
                    :remove_compositions => false,
                    :annotations => ['task_info'].to_set
                ]

                buttons = []
                Syskit::Graphviz.available_annotations.sort.each do |ann_name|
                    buttons << HTML::Button.new("annotations/#{ann_name}",
                                                :on_text => "Show #{ann_name}",
                                                :off_text => "Hide #{ann_name}",
                                                :state => dataflow_options[:annotations].include?(ann_name))
                end
                connect(page, SIGNAL('buttonClicked(const QString&,bool)'), self, SLOT('buttonClicked(const QString&,bool)'))
                dataflow_options[:buttons] = buttons
            end

            def render(model, options = Hash.new)
                super

                plan.clear
                options = Kernel.validate_options options, :method => :instanciate_model
                @task = begin send(options[:method], model, plan)
                        rescue Exception => e
                            if view_partial_plans? then
                                Roby.app.register_exception(e)
                                nil
                            else raise
                            end
                        end

                page.push_plan('Task Dependency Hierarchy', 'hierarchy', plan, hierarchy_options)
                page.push_plan('Dataflow', 'dataflow', plan, dataflow_options)

                emit updated
            end

            def buttonClicked(button_id, new_state)
                if button_id =~ /\/annotations\/(\w+)/
                    ann_name = $1
                    if new_state then dataflow_options[:annotations] << ann_name
                    else dataflow_options[:annotations].delete(ann_name)
                    end
                end
                page.push_plan('Dataflow', 'dataflow', plan, dataflow_options)
            end
            slots 'buttonClicked(const QString&,bool)'
        end
    end
end

