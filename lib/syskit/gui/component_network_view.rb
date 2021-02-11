# frozen_string_literal: true

require "metaruby/gui/html/button"
require "syskit/gui/component_network_base_view"
module Syskit
    module GUI
        # Generic component network visualization
        #
        # It displays the task hierarchy as well as the dataflow network
        class ComponentNetworkView < ComponentNetworkBaseView
            # @!method view_partial_plans?
            # @!method view_partial_plans=(flag)
            #
            # Whether the plan should be displayed regardless of errors during
            # deployment or not. It defaults to true.
            attr_predicate :view_partial_plans?, true

            # Default rendering options for {ComponentNetworkBaseView#push_plan}
            # for the dataflow graph
            attr_reader :dataflow_options

            # Default rendering options for {ComponentNetworkBaseView#push_plan}
            # for the hierarchy graph
            attr_reader :hierarchy_options

            # The plan object that holds the network we render
            #
            # @return [Roby::Plan]
            attr_reader :plan

            # The toplevel task for the last rendered model
            #
            # Set by {#render}
            #
            # @return [Syskit::Component]
            attr_reader :task

            def initialize(page)
                super
                @view_partial_plans = true
                @plan = Roby::Plan.new

                @hierarchy_options = Hash[
                    title: "Task Dependency Hierarchy",
                    id: "hierarchy",
                    remove_compositions: false,
                    annotations: %w[task_info port_details].to_set,
                    zoom: 1
                ]
                @dataflow_options = Hash[
                    title: "Dataflow",
                    id: "dataflow",
                    remove_compositions: false,
                    show_all_ports: false,
                    annotations: ["task_info"].to_set,
                    excluded_models: Set.new,
                    zoom: 1
                ]

                buttons = []
                buttons << Button.new("dataflow/show_compositions",
                                      on_text: "Show compositions",
                                      off_text: "Hide compositions",
                                      state: !dataflow_options[:remove_compositions])
                buttons << Button.new("dataflow/show_all_ports",
                                      on_text: "Show all ports",
                                      off_text: "Hide unused ports",
                                      state: dataflow_options[:show_all_ports])

                if defined? OroGen::Logger::Logger
                    dataflow_options[:excluded_models] << OroGen::Logger::Logger
                    buttons << Button.new("dataflow/show_loggers",
                                          on_text: "Show loggers",
                                          off_text: "Hide loggers",
                                          state: false)
                end

                buttons.concat(self.class.common_graph_buttons("dataflow"))
                buttons.concat(
                    self.class.task_annotation_buttons(
                        "dataflow", dataflow_options[:annotations]
                    )
                )
                buttons.concat(
                    self.class.graph_annotation_buttons(
                        "dataflow", dataflow_options[:annotations]
                    )
                )
                dataflow_options[:buttons] = buttons

                buttons = []
                buttons.concat(self.class.common_graph_buttons("hierarchy"))
                hierarchy_options[:buttons] = buttons
            end

            def add_button(button)
                add_dataflow_button(button)
                add_hierarchy_button(button)
            end

            def add_dataflow_button(button)
                dataflow_options[:buttons] << button
            end

            def add_hierarchy_button(button)
                hierarchy_options[:buttons] << button
            end

            # Render a model on this view
            #
            # @param [Model<Component>] model
            # @param [Symbol] method how to render the model. It either is
            #   :instanciate_model
            #   (#{ComponentNetworkBaseView#instanciate_model}) or
            #   :compute_system_network (#{ComponentNetworkBaseView#compute_system_network})
            # @param [Boolean] show_requirements whether
            #   model.to_instance_requirements should be rendered as well
            # @param [Hash] instanciate_options options to be passed to
            #   {ComponentNetworkBaseView#instanciate_model} if 'method' is
            #   :intsanciate_model
            # @param [Hash] dataflow additional arguments for the rendering of the
            #   dataflow grap in {#render_plan}
            # @param [Hash] hierarchy additional arguments for the rendering of the
            #   hierarchy graph in {#render_plan}
            # @param [Hash] render_options additional options for the rendering
            #   of both graphs in {#render_plan}
            def render(model,
                method: :instanciate_model,
                name: model.object_id.to_s,
                show_requirements: false,
                instanciate_options: {},
                dataflow: {},
                hierarchy: {},
                **render_options)
                super

                plan.clear

                if show_requirements
                    html = ModelViews.render_instance_requirements(
                        page,
                        model.to_instance_requirements,
                        resolve_dependency_injection: true
                    ).join("\n")
                    page.push("Resolved Requirements", "<pre>#{html}</pre>")
                end

                begin
                    if method == :compute_system_network
                        tic = Time.now
                        @task = compute_system_network(model, plan)
                        timing = Time.now - tic
                    elsif method == :compute_deployed_network
                        tic = Time.now
                        @task = compute_deployed_network(model, plan)
                        timing = Time.now - tic
                    else
                        @task = instanciate_model(model, plan, instanciate_options)
                    end
                rescue StandardError => e
                    raise unless view_partial_plans?

                    exception = e
                end

                if timing
                    html = format("<p>Network generated in %<timing>.3f</p>",
                                  timing: timing)
                    page.push("", html, id: "timing-#{name}")
                end

                hierarchy_options = self.hierarchy_options
                                        .merge(render_options)
                                        .merge(hierarchy)
                hierarchy_options = process_options(
                    "hierarchy", model, name: name, **hierarchy_options
                )
                dataflow_options = self.dataflow_options
                                       .merge(render_options)
                                       .merge(dataflow)
                dataflow_options = process_options(
                    "dataflow", model, name: name, **dataflow_options
                )

                render_plan(hierarchy: hierarchy_options,
                            dataflow: dataflow_options)
                raise exception if exception
            end

            def process_options(kind, _model, name:, **options)
                if options[:id]
                    options[:id] = format(
                        options[:id].to_str, "#{kind}-#{name}"
                    )
                end

                if (externals = options[:external_objects])
                    options[:external_objects] = format(
                        externals.to_str, "#{kind}-#{name}"
                    )
                end
                options
            end

            # Renders {#plan}
            #
            # This renders the plan's hierarchy and dataflow
            #
            # @param [Hash] hierarchy options to pass to
            #   {ComponentNetworkBaseView#push_plan} in addition to 'options'
            #   and {#hierarchy_options}
            # @param [Hash] dataflow options to pass to
            #   {ComponentNetworkBaseView#push_plan} in addition to 'options'
            #   and {#dataflow_options}
            # @param [Hash] options options that should be passed to
            # {#push_plan} for both the hierarchy and dataflow graphs
            def render_plan(hierarchy: {}, dataflow: {}, **options)
                all_annotations = Syskit::Graphviz.available_annotations.to_set

                hierarchy_options = options
                                    .merge(self.hierarchy_options)
                                    .merge(hierarchy)
                push_plan("hierarchy", plan, hierarchy_options)

                dataflow_options = { annotations: all_annotations }
                                   .merge(self.dataflow_options)
                                   .merge(options)
                                   .merge(dataflow)
                push_plan("dataflow", plan, dataflow_options)

                emit updated
            end
        end
    end
end
