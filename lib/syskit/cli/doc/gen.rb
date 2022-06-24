# frozen_string_literal: true

require "syskit"

module Syskit
    module CLI
        # Functionality for the `syskit doc gen` command
        module Doc
            # Generate the network graph for the model defined in a given path
            #
            # It is saved under the target path, in a folder that matches the
            # namespace (the same way YARD does)
            def self.generate(app, required_paths, target_path)
                required_paths = required_paths.map(&:to_s).to_set
                models = app.each_model.find_all do |m|
                    if (location = app.definition_file_for(m))
                        required_paths.include?(location)
                    end
                end

                app.default_loader.loaded_typekits.each do |_, tk|
                    save_typekit(target_path, tk)
                end

                models.each do |m|
                    save_model(target_path, m)
                end
            end

            # Save metadata related to a given model
            #
            # @param [Pathname] target_path the root of the documentation output path
            # @param model the model to export
            def self.save_model(target_path, model) # rubocop:disable Metrics/CyclomaticComplexity
                case model
                when Syskit::Actions::Profile
                    save_profile_model(target_path, model)
                when Syskit::Models::DataServiceModel
                    save_data_service_model(target_path, model)
                when Class
                    if model <= Syskit::Composition
                        save_composition_model(target_path, model)
                    elsif model <= Syskit::RubyTaskContext
                        save_ruby_task_context_model(target_path, model)
                    elsif model <= Syskit::TaskContext
                        save_task_context_model(target_path, model)
                    end
                end
            end

            def self.save_profile_model(target_path, profile_m)
                definitions_path = path_for_model(target_path, profile_m)
                definitions_path.mkpath

                definitions = profile_m.each_resolved_definition.map do |profile_def|
                    { "name" => profile_def.name }.merge(
                        save_profile_definition(definitions_path, profile_def)
                    )
                end

                profile_info = { "definitions" => definitions }
                save(target_path, profile_m, ".yml", YAML.dump(profile_info))
            end

            # Save data for a given profile definition within a profile
            #
            # @param [Pathname] target_path the profile-specific path into which
            #   the definition information should be saved
            # @param [Actions::Profile::Definition] profile_def
            def self.save_profile_definition(target_path, profile_def)
                task = compute_system_network(
                    profile_def,
                    validate_abstract_network: false,
                    validate_generated_network: false
                )

                hierarchy_path, dataflow_path =
                    save_profile_definition_graphs(target_path, task, profile_def)

                {
                    "name" => profile_def.name,
                    "doc" => profile_def.doc,
                    "model" => profile_def.model.name,
                    "graphs" => {
                        "hierarchy" => hierarchy_path.to_s,
                        "dataflow" => dataflow_path.to_s
                    }
                }
            end

            def self.save_profile_definition_graphs(target_path, task, profile_def)
                hierarchy = render_plan(task.plan, "hierarchy")
                dataflow = render_plan(task.plan, "dataflow")

                hierarchy_path = (target_path / "#{profile_def.name}.hierarchy.svg")
                hierarchy_path.write(hierarchy)
                dataflow_path = (target_path / "#{profile_def.name}.dataflow.svg")
                dataflow_path.write(dataflow)

                [hierarchy_path, dataflow_path]
            end

            def self.save_data_service_model(target_path, service_m)
                task = Syskit::Models::Placeholder.for([service_m]).new
                interface = render_plan(task.plan, "dataflow")
                interface_path =
                    save(target_path, service_m, ".interface.svg", interface)

                description = service_model_description(service_m)
                description = description.merge(
                    { "graphs" => { "interface" => interface_path.to_s } }
                )
                save target_path, service_m, ".yml", YAML.dump(description)
            end

            def self.save_composition_model(target_path, composition_m)
                hierarchy, dataflow = render_composition_graphs(composition_m)
                hierarchy_path =
                    save(target_path, composition_m, ".hierarchy.svg", hierarchy)
                dataflow_path =
                    save(target_path, composition_m, ".dataflow.svg", dataflow)

                description = composition_model_description(composition_m)
                description = description.merge(
                    {
                        "graphs" => {
                            "hierarchy" => hierarchy_path.to_s,
                            "dataflow" => dataflow_path.to_s
                        }
                    }
                )
                save target_path, composition_m, ".yml", YAML.dump(description)
            end

            def self.save_ruby_task_context_model(target_path, task_m)
                save_task_context_model(target_path, task_m)
            end

            def self.save_task_context_model(target_path, task_m)
                task = task_m.new
                interface = render_plan(task.plan, "dataflow")
                interface_path =
                    save(target_path, task_m, ".interface.svg", interface)

                description = component_model_description(task_m)
                description = description.merge(
                    { "graphs" => { "interface" => interface_path.to_s } }
                )
                save target_path, task_m, ".yml", YAML.dump(description)
            end

            def self.save_typekit(root_path, typekit)
                typekits_path = root_path / "typekits"
                typekits_path.mkpath

                (typekits_path / "#{typekit.name}.tlb").write typekit.registry.to_xml
            end

            def self.task_model_description(task_m)
                events = task_m.each_event.map do |name, ev|
                    { "name" => name.to_s, "description" => ev.doc }
                end
                { "events" => events }
            end

            def self.component_model_description(component_m)
                ports = list_ports(component_m)
                services = list_bound_services(component_m)
                task_model_description(component_m)
                    .merge({ "ports" => ports, "bound_services" => services })
            end

            ROOT_SERVICE_MODELS = [Syskit::DataService, Syskit::Device].freeze

            def self.service_model_description(service_m)
                services = service_model_provided_models(service_m)
                ports = list_ports(service_m)
                { "ports" => ports, "provided_services" => services.compact }
            end

            def self.service_model_provided_models(service_m, mapping_to: service_m)
                service_m.each_fullfilled_model.map do |provided_service_m|
                    next if ROOT_SERVICE_MODELS.include?(provided_service_m)
                    next if provided_service_m == service_m

                    mappings = mapping_to.port_mappings_for(provided_service_m)
                    { "model" => provided_service_m.name, "mappings" => mappings }
                end.compact
            end

            def self.composition_model_description(composition_m)
                component_model_description(composition_m)
            end

            # Compute the base path to be used to save data for a given model
            #
            # @param [Pathname] root_path
            # @param {#name} model
            def self.path_for_model(root_path, model)
                name = model.name
                unless name
                    puts "ignoring model #{model} as its name is invalid"
                    return
                end

                components = name.split(/::|\./)
                components.inject(root_path, &:/)
            end

            # Save data at the canonical path for the given model
            #
            # @param [Pathname] root_path the root of the output path hierarchy
            # @param model the model we save the data for
            # @param [String] suffix the file name suffix
            # @param [String] data the data to save
            # @return [Pathname,nil] full path to the saved data, or nil if the method
            #   could not save anything
            def self.save(root_path, model, suffix, data)
                return unless (target_path = path_for_model(root_path, model))

                target_path.dirname.mkpath

                target_file = target_path.sub_ext(suffix)
                target_file.write(data)
                target_file
            end

            def self.render_composition_graphs(composition_m)
                task = instanciate_model(composition_m)
                [render_plan(task.plan, "hierarchy"),
                 render_plan(task.plan, "dataflow")]
            end

            # Compute the system network for a model
            #
            # @param [Model<Component>] model the model whose representation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.compute_system_network(model, main_plan = Roby::Plan.new, **options)
                main_plan.add(original_task = model.as_plan)
                engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                planning_task = original_task.planning_task
                mapping = engine.compute_system_network([planning_task], **options)

                if engine.work_plan.respond_to?(:commit_transaction)
                    engine.work_plan.commit_transaction
                end

                main_plan.remove_task(original_task)
                mapping[planning_task]
            end

            # Compute the deployed network for a model
            #
            # @param [Model<Component>] model the model whose representation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.compute_deployed_network(model, main_plan = Roby::Plan.new)
                main_plan.add(original_task = model.as_plan)
                base_task = original_task.as_service
                resolve_system_network(base_task.task.planning_task)

                base_task.task
            ensure
                if engine && engine.work_plan.respond_to?(:commit_transaction)
                    engine.commit_work_plan
                    main_plan.remove_task(original_task)
                end
            end

            # Resolve the system network of a given task
            #
            # It attempts to generate a network in case of errors too, by disabling
            # validation
            #
            # @return [Boolean] true if an error ocurred, false otherwise
            def self.resolve_system_network(planning_task)
                engine = Syskit::NetworkGeneration::Engine.new(planning_task.plan)
                engine.resolve_system_network([planning_task])
                true
            rescue RuntimeError
                engine = Syskit::NetworkGeneration::Engine.new(planning_task.plan)
                engine.resolve_system_network(
                    [planning_task],
                    validate_abstract_network: false,
                    validate_generated_network: false,
                    validate_deployed_network: false
                )
                false
            ensure
                NetworkGeneration::LoggerConfigurationSupport
                    .add_logging_to_network(engine, engine.work_plan)
            end

            # Instanciate a model
            #
            # @param [Model<Component>] model the model whose instanciation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @param [Hash] options options to be passed to
            #   {Syskit::InstanceRequirements#instanciate}
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.instanciate_model(model, main_plan = nil, options = {})
                main_plan ||= Roby::Plan.new
                requirements = model.to_instance_requirements
                task = requirements.instanciate(
                    main_plan,
                    Syskit::DependencyInjectionContext.new,
                    options
                )
                main_plan.add(task)
                task
            rescue StandardError => e
                Roby.warn "could not instanciate #{model}"
                Roby.log_exception_with_backtrace(e, Roby, :warn)
                requirements.model.new
            end

            # List the services provided by a component
            #
            # @param [Component] component_m the component model
            def self.list_bound_services(component_m)
                component_m.each_data_service.sort_by(&:first)
                           .map do |service_name, service|
                    provided_services =
                        service_model_provided_models(service.model, mapping_to: service)

                    { "name" => service_name, "model" => service.model.name,
                      "provided_services" => provided_services }
                end
            end

            def self.list_ports(model)
                model.each_port.map do |p|
                    { "name" => p.name, "type" => p.type.name,
                      "direction" => p.output? ? "out" : "in",
                      "doc" => p.doc }
                end
            end

            # Generate a SVG of the a certain graph from a plan
            #
            # @param [Roby::Plan] the plan to generate the SVG for
            # @param [String] graph_kind either hierarchy or dataflow
            # @return [String]
            def self.render_plan(
                plan, graph_kind, typelib_resolver: nil, **graphviz_options
            )
                begin
                    svg_io = Tempfile.open(graph_kind)
                    Syskit::Graphviz
                        .new(plan, self, typelib_resolver: typelib_resolver)
                        .to_file(graph_kind, "svg", svg_io, **graphviz_options)
                    svg_io.flush
                    svg_io.rewind
                    svg = svg_io.read
                    svg = svg.encode "utf-8", invalid: :replace
                rescue DotCrashError, DotFailedError => e
                    svg = e.message
                ensure
                    svg_io&.close
                end

                # Fixup a mixup in dot's SVG output. The URIs that contain < and >
                # are not properly escaped to &lt; and &gt;
                svg = svg.gsub(/xlink:href="[^"]+"/) do |match|
                    match.gsub("<", "&lt;").gsub(">", "&gt;")
                end

                svg
            end
        end
    end
end
