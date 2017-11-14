using_task_library '<%= orogen_project_name %>'
<% indent, open, close = ::Roby::App::GenBase.in_module("OroGen") %>
<%= open %>
<% orogen_models.each do |model| %>
<%= indent %>describe OroGen.<%= model.name.gsub("::", ".") %> do
<%= indent %>    it { is_configurable }
<%= indent %>end
<% end %>
<%= close %>
