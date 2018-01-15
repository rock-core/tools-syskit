using_task_library '<%= orogen_project_name %>'

module OroGen<% orogen_models.each do |model| %>
    describe <%= model.name.gsub("::", ".") %> do
        it { is_configurable }
    end
<% end %>end
