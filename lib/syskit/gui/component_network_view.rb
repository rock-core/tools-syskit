require 'syskit/gui/component_network_base_view'
module Syskit
    module GUI
        # Generic component network visualization
        #
        # It displays the task hierarchy as well as the dataflow network
        class ComponentNetworkView < ComponentNetworkBaseView
            attr_predicate :view_partial_plans?, true

            def initialize(parent = nil)
                super
                @view_partial_plans = true
            end

            def render(model, options = Hash.new)
                super

                plan = Roby::Plan.new
                error = nil
                options = Kernel.validate_options options, :method => :instanciate_model
                begin send(options[:method], model, plan)
                rescue Exception => e
                    if view_partial_plans? then error = e
                    else raise
                    end
                end

                plan_display_options = Hash[
                    :remove_compositions => false,
                    :annotations => ['task_info', 'port_details'].to_set
                ]
                push_plan('Task Dependency Hierarchy', 'hierarchy', plan, Roby.syskit_engine, plan_display_options)
                default_widget = push_plan('Dataflow', 'dataflow', plan, Roby.syskit_engine, plan_display_options)

                self.current_widget = default_widget
                if error then raise error
                end
            end
        end
    end
end

