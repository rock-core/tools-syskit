# frozen_string_literal: true

module Syskit
    module Interface
        module V2
            # Syskit extensions to Roby's v2 interface wire protocol
            module Protocol
                Deployment = Struct.new(
                    :roby_task, :pid, :ready_since, :iors, keyword_init: true
                ) do
                    def pretty_print(pp)
                        roby_task.pretty_print(pp)
                        pp.breakable
                        pp.text "PID: #{pid}"
                        pp.breakable
                        pp.text "Deployed tasks: #{iors.keys.join(', ')}"
                    end
                end

                module Models
                    TaskContext = Struct.new(
                        :orogen_model_name, :ports, :properties, keyword_init: true
                    ) do
                        def pretty_print(pp)
                            pp.text orogen_model_name
                            pp.breakable
                            pp_ports(pp)
                            pp.breakable
                            pp_properties(pp)
                        end

                        def pp_ports(pp)
                            pp.text "Ports:"
                            pp.nest(2) do
                                ports.each do |p|
                                    p.breakable
                                    p.pretty_print(pp)
                                end
                            end
                        end

                        def pp_properties(pp)
                            pp.text "Properties:"
                            pp.nest(2) do
                                properties.each do |p|
                                    p.breakable
                                    p.pretty_print(pp)
                                end
                            end
                        end
                    end

                    Port = Struct.new(:name, :type, :input, keyword_init: true) do
                        def input?
                            input
                        end

                        def pretty_print(pp)
                            pp.text "#{name} (#{type.name})"
                            pp.breakable
                            type.pretty_print(pp)
                        end
                    end

                    Property = Struct.new(:name, :type, keyword_init: true) do
                        def pretty_print(pp)
                            pp.text "#{name} (#{type.name})"
                            pp.breakable
                            type.pretty_print(pp)
                        end
                    end
                end

                Type = Struct.new(:name, :xml, keyword_init: true) do
                    def pretty_print(pp)
                        pp.text "#{name} "
                        Typelib::Type.from_xml(xml).pretty_print(pp)
                    end
                end

                def self.register_marshallers(protocol)
                    protocol.add_model_marshaller(
                        Syskit::TaskContext, &method(:marshal_model_taskcontext)
                    )
                    protocol.add_marshaller(
                        Syskit::Deployment, &method(:marshal_deployment_task)
                    )
                end

                def self.marshal_type(_channel, type)
                    Type.new(name: type.name, xml: type.to_xml)
                end

                def self.marshal_model_taskcontext_ports(channel, model)
                    model.each_port.map do |p|
                        Models::Port.new(
                            name: p.name, type: marshal_type(channel, p.type),
                            input: p.input?
                        )
                    end
                end

                def self.marshal_model_taskcontext_properties(channel, model)
                    model.each_property.map do |p|
                        Models::Property.new(
                            name: p.name, type: marshal_type(channel, p.type)
                        )
                    end
                end

                def self.marshal_model_taskcontext(channel, model)
                    Models::TaskContext.new(
                        orogen_model_name: model.orogen_model.name,
                        ports: marshal_model_taskcontext_ports(channel, model),
                        properties: marshal_model_taskcontext_properties(channel, model)
                    )
                end

                def self.marshal_deployment_task(channel, task)
                    Deployment.new(
                        roby_task: Roby::Interface::V2::Protocol.marshal_task(
                            channel, task
                        ),
                        pid: task.pid,
                        ready_since: task.ready_event.last&.time,
                        iors: task.remote_task_handles.transform_values { _1.handle.ior }
                    )
                end
            end
        end
    end
end
