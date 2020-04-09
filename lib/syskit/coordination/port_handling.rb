# frozen_string_literal: true

module Syskit
    module Coordination
        # Port access code for instance-level task objects
        module PortHandling
            def has_port?
                !!model.find_port(port_name)
            end

            def find_port(port_name)
                if model_port = model.find_port(port_name)
                    case model_port
                    when Syskit::Models::OutputPort
                        OutputPort.new(model_port, model_port.component_model.bind(self))
                    when Syskit::Models::InputPort
                        InputPort.new(model_port, model_port.component_model.bind(self))
                    end
                end
            end

            def self_port_to_component_port(port)
                port_model   = port.model
                model_object = port_model.component_model
                component_model = model_object.model

                if respond_to?(:parent)
                    component_model.resolve_and_bind_child(parent.resolve).self_port_to_component_port(port)
                else
                    component_model.bind(resolve).self_port_to_component_port(port)
                end
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(self, m, "_port" => :has_port?) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(self, m, args, "_port" => :find_port) || super
            end
        end

        class OutputPort < Syskit::OutputPort
            def reader(policy = {})
                # The 'rescue' case is used only on first evaluation of the
                # block, when Roby instanciates it to check syntax.
                # The script blocks have to be re-instanciated for each
                # task they get applied on
                begin
                    component.resolve
                    root_task = component.root_task.resolve
                    reader = super
                    root_task.stop_event.on { |_| reader.disconnect }
                    reader
                rescue Roby::Coordination::ResolvingUnboundObject
                    Syskit::Models::OutputReader.new(self, policy)
                end
            end
        end

        class InputPort < Syskit::InputPort
            def writer(policy = {})
                # The 'rescue' case is used only on first evaluation of the
                # block, when Roby instanciates it to check syntax.
                # The script blocks have to be re-instanciated for each
                # task they get applied on
                begin
                    component.resolve
                    root_task = component.root_task.resolve
                    writer = super
                    root_task.stop_event.on { |_| writer.disconnect }
                    writer
                rescue Roby::Coordination::ResolvingUnboundObject
                    Syskit::Models::InputWriter.new(self, policy)
                end
            end
        end
    end
end

Roby::Coordination::TaskBase.include Syskit::Coordination::PortHandling
