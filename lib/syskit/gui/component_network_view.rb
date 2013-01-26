require 'syskit/gui/component_network_base_view'
module Syskit
    module GUI
        # Generic component network visualization
        #
        # It displays the task hierarchy as well as the dataflow network
        class ComponentNetworkView < ComponentNetworkBaseView
            def render(model, options = Hash.new)
                super

                options = Kernel.validate_options options, :method => :instanciate_model
                task = send(options[:method], model)
                task = task.to_task

                plan_display_options = Hash[
                    :remove_compositions => false,
                    :annotations => ['task_info', 'port_details'].to_set
                ]
                push_plan('Task Dependency Hierarchy', 'hierarchy', task.plan, Roby.syskit_engine, plan_display_options)
                default_widget = push_plan('Dataflow', 'dataflow', task.plan, Roby.syskit_engine, plan_display_options)

                self.current_widget = default_widget
            end
        end
    end
end

