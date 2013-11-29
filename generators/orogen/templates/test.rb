using_task_library '<%= orogen_project_name %>'
<% indent, open, close = ::Roby::App::GenBase.in_module(orogen_project_module_name) %>
<%= open %>
<% classes.each do |class_name| %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>end
<% end %>
<%= close %>
