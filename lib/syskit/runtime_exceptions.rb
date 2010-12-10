module Orocos
    module RobyPlugin
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

                    if failed_task.model.private_specialization?
                        dynamic_model, static_model =
                            failed_task.model, failed_task.model.superclass
                    else
                        dynamic_model, static_model =
                            nil, failed_task.model
                    end

                    # Might have been a wrong configure() implementation. Check.
                    if dynamic_model &&
                        dynamic_model.send("find_#{port_kind}_port", port_name) &&
                        !static_model.send("find_#{port_kind}_port", port_name)

                        pp.text "it is a dynamic port that should have been created by #{static_model.short_name}#configure"
                    end

                    if static_model.send("find_#{port_kind}_port", port_name)
                        pp.text "it is a static port that should be there on every task of type #{static_model.short_name}"
                    end

                    # Check for com bus (they do not use dynamic slaves yet)
                    if failed_task.respond_to?(:port_to_device) &&
                        (device_name = failed_task.port_to_device[port_name])

                        pp.text "it is a dynamic port that should have been created by #{static_model.short_name}#configure to accomodate the device(s) #{device_name.join(", ")}"
                    end
                end
            end
        end
    end
end

