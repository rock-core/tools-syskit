# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # System-level definition of a remote Syskit instance
            class RemoteSystem
                def initialize
                    rtt_loader = OroGen::Loaders::RTT.new
                    @loader = OroGen::Loaders::Base.new(rtt_loader)
                    @registry = Typelib::Registry.new
                end

                # Return an orogen model from its name
                #
                # @return [OroGen::Spec::TaskContext,nil]
                def type_from_name(name)
                    @loader.resolve_type(name)
                end

                # Return an orogen model from its name
                #
                # @return [OroGen::Spec::TaskContext,nil]
                def find_task_model_from_name(name)
                    @loader.task_model_from_name(name)
                rescue OroGen::Spec::TaskModelNotFound
                    nil
                end

                # Update system information from a Protocol::SystemDefinitions
                def update_from_protocol(sysdef)
                    @registry.merge(Typelib::Registry.from_xml(sysdef.registry))

                    # The simplifying assumption here is that we register all task
                    # contexts of a given project at once
                    by_project = sysdef.orogen_models.group_by { _1.project_name }
                    by_project.each do |project_name, models|
                        next if @loader.has_loaded_project?(project_name)

                        project = OroGen::Spec::Project.new(@loader)
                        project.name project_name
                        models.each do |m|
                            register_orogen_model_from_protocol(project, m)
                        end
                    end
                end

                # @api private
                #
                # Register an orogen model object based on the information received from
                # {Protocol}
                #
                # @param [Protocol::OroGenModel] model
                # @param [Typelib::Registry] registry
                # @return [OroGen::Spec::TaskContext] the generated orogen model. It is
                #   already registered on this object's loader when the method returns
                def register_orogen_model_from_protocol(project, protocol)
                    model = OroGen::Spec::TaskContext.new(project, protocol.name)
                    register_orogen_model_properties_from_protocol(model, protocol)
                    register_orogen_model_attributes_from_protocol(model, protocol)
                    register_orogen_model_ports_from_protocol(model, protocol)
                    register_orogen_model_dynamic_ports_from_protocol(model, protocol)
                    register_orogen_model_states_from_protocol(model, protocol)
                    @loader.register_task_context_model(model)
                    model
                end

                def register_orogen_model_properties_from_protocol(model, protocol)
                    protocol.properties.each do |p|
                        type = resolve_interface_type(p.type_name)
                        model.property p.name, type
                    end
                end

                def register_orogen_model_attributes_from_protocol(model, protocol)
                    protocol.attributes.each do |a|
                        type = resolve_interface_type(a.type_name)
                        model.attribute a.name, type
                    end
                end

                def register_orogen_model_ports_from_protocol(model, protocol)
                    protocol.ports.each do |p|
                        type = resolve_interface_type(p.type_name)
                        if p.input
                            model.input_port p.name, type
                        else
                            model.output_port p.name, type
                        end
                    end
                end

                def register_orogen_model_dynamic_ports_from_protocol(model, protocol)
                    protocol.dynamic_ports.each do |p|
                        type = resolve_interface_type(p.type_name)
                        if p.input
                            model.dynamic_input_port p.name_pattern, type
                        else
                            model.dynamic_output_port p.name_pattern, type
                        end
                    end
                end

                def register_orogen_model_states_from_protocol(model, protocol)
                    protocol.states.each do |name, kind|
                        next if kind == :toplevel

                        model.send("#{kind}_states", name)
                    end
                end

                # @api private
                #
                # Build a type and register it on the loader as an interface type
                def resolve_interface_type(name)
                    type = @registry.build(name)
                    @loader.register_type_model(type)
                    type
                end
            end
        end
    end
end
