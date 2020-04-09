# frozen_string_literal: true

module Syskit
    class PortNotFound < Roby::LocalizedError
        attr_reader :port_name
        attr_reader :port_kind

        def initialize(task, name, kind)
            @port_name = name
            @port_kind = kind
            super(task)
        end

        def pretty_print(pp)
            pp.text "#{self.class}: #{failed_task} has connections but there are missing ports on the actual RTT task"
            pp.nest(2) do
                pp.breakable
                pp.text "the RTT task #{failed_task.orocos_name} of type #{failed_task.model.short_name} was expected to have a port called #{port_name}, but does not."
                pp.breakable

                dynamic_model = failed_task.model
                static_model = failed_task.concrete_model

                # Might have been a wrong configure() implementation. Check.
                if dynamic_model&.send("find_#{port_kind}_port", port_name) &&
                    !static_model.send("find_#{port_kind}_port", port_name)

                    pp.text "it is a dynamic port that should have been created by #{static_model.short_name}#configure"
                elsif static_model.send("find_#{port_kind}_port", port_name)
                    pp.text "it is a static port that should be there on every task of type #{static_model.short_name}"
                end
            end
        end
    end
end
