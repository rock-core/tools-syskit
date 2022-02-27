# frozen_string_literal: true

module Syskit
    module RobyApp
        module REST
            # Endpoints to access orogen information
            #
            # Usually available under /syskit/orogen
            class OroGen < Grape::API
                helpers Roby::Interface::REST::Helpers

                # Return the textual description of an orogen model
                params do
                    requires :project_name, type: String
                end
                get "/projects/:project_name" do
                    text, path = roby_app.default_loader.project_model_text_from_name(
                        params[:project_name]
                    )
                    { orogen_model: text }
                rescue OroGen::NotFound
                    error!(404, "#{params[:project_name]} does not seem to be "\
                                "a valid oroGen project model")
                end

                # Return the description of the given types
                params do
                    requires :names, type: Array
                end
                get "/types" do
                    global_registry = Typelib::Registry.new
                    params[:names].each do |name|
                        # Make sure the type is loaded
                        roby_app.default_pkgconfig_loader
                                .typekit_for(name, false)
                        # And resolve it
                        type = roby_app.default_loader
                                       .resolve_type(name)

                        global_registry.merge(type.minimal)
                    end

                    { typelib_xml: global_registry.to_xml }
                rescue OroGen::NotFound
                    error!(404, "#{params[:name]} does not seem to be "\
                                "a valid oroGen task context model")
                end

                # Return a minimal JSON description of an orogen task context
                params do
                    requires :name, type: String
                end
                get "/task_context/:name" do
                    orogen_task_context_to_json(
                        roby_app.default_loader.task_model_from_name(params[:name])
                    )
                rescue OroGen::NotFound
                    error!(404, "#{params[:name]} does not seem to be "\
                                "a valid oroGen task context model")
                end

                helpers do
                    def task_context_to_json(task_context_m)
                        model = {
                            name: task_context_m.name,
                            ports: [], properties: []
                        }
                        task_context_m.each_input_port do |port|
                            { name: port.name, type: port.type.name,
                              direction: "in" }
                        end
                        task_context_m.each_output_port do |port|
                            { name: port.name, type: port.type.name,
                              direction: "out" }
                        end
                        task_context_m.each_property do |property|
                            { name: property.name, type: property.type.name }
                        end
                    end
                end
            end
        end
    end
end
