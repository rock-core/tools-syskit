# frozen_string_literal: true

module Syskit::GUI
    module ModelViews
        class TaskContext < TaskContextBase
            def render_require_section(model)
                if model.extension_file
                    ComponentNetworkBaseView.html_defined_in(
                        page, model,
                        definition_location: [model.extension_file, 1],
                        with_require: false,
                        format: "<b>Extended in</b> %s"
                    )
                    page.push nil, "<code>using_task_library \"#{model.orogen_model.project.name}\"</code>"
                else
                    page.push nil, "There is no extension file for this model. You can run <tt>syskit gen orogen #{model.orogen_model.project.name}</tt> to create one, and press the 'Reload Models' button above"
                    page.push nil, "<code>using_task_library \"#{model.orogen_model.project.name}\"</code>"
                end
            end
        end
    end
end
