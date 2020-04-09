# frozen_string_literal: true

module Syskit::GUI
    module ModelViews
        class TaskContextBase < Component
            attr_reader :orogen_rendering
            attr_reader :task_model_view

            def initialize(page)
                super(page)
                @task_model_view = Roby::GUI::ModelViews::Task.new(page)
                @orogen_rendering = OroGen::HTML::TaskContext.new(page)
                buttons = []
                buttons.concat(self.class.common_graph_buttons("interface"))

                all_annotations = Syskit::Graphviz.available_task_annotations.sort
                buttons.concat(self.class.make_annotation_buttons("interface", all_annotations, all_annotations))
                Syskit::Graphviz.available_task_annotations.sort.each do |ann_name|
                    interface_options[:annotations] << ann_name
                end
                interface_options[:buttons] = buttons
            end

            def render_doc(model)
                doc = [model.doc, model.orogen_model.doc].compact.join("\n\n").strip
                unless doc.empty?
                    page.push nil, page.main_doc(doc)
                end
            end

            def render(model, external_objects: false)
                super

                page.push("oroGen Model", "<p><b>oroGen name:</b> #{model.orogen_model.name}</p>")
                orogen_rendering.render(model.orogen_model, external_objects: external_objects, doc: false)

                task_model_view.render(model, external_objects: external_objects)
            end
        end
    end
end
